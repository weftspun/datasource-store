# RFD 0001 — TLS for the FoundationDB cluster, and why the identity is the hard part

State: **open**. The certificate authority is built and working; the machine identity it
issues against is not settled, and that is what this asks for discussion on.

Backfilled after the work rather than before it, so the measurements below are what happened
rather than what was expected.

## What is decided and working

**A private CA, not a public one.** OpenBao (MPL-2.0) runs the PKI engine with a self-signed
root, `Weftspun FDB Root CA`, 10 years. Single-key seal — `-key-shares=1 -key-threshold=1` —
with the unseal key and root token in 1Password rather than on disk.

Self-signed matters more than it sounds. FoundationDB requires a path to a **self-signed**
trust anchor, and Let's Encrypt's chain ends at a *cross-signed* root. Every handshake failed
with `TLSPolicyFailure Reason="preverification"` and nothing said so. A private root is an
anchor by construction, which removes the failure rather than working around it.

**No wildcard, enforced twice.** The cluster verifies `Check.Valid=1,S.CN=fdb-*`; the CA role
is `allowed_domains="fdb-*.chibifire.com"` with `allow_wildcard_certificates=false` and
`allow_bare_domains=false`. Measured:

    fdb-3678.chibifire.com     ISSUED
    fdb-zzzz.chibifire.com     ISSUED
    www.chibifire.com          refused
    chibifire.com              refused
    *.chibifire.com            refused

The first version of the role allowed *any* subdomain and would have minted
`www.chibifire.com` — a certificate the cluster then rejects, putting the policy in one of
the two places it needs to be. A negative control caught it; without one this would have been
reported as a working CA.

The previously issued `*.chibifire.com` is revoked, serial
`054631565CEC358B51D513EE16F8A8BC63CF`.

## What is open, and the reason this is an RFD

**A NIC is not a stable identity on Fly, and the whole scheme rested on it.**

Certificates were issued as `fdb-<last four of the NIC>.chibifire.com`, giving `fdb-3678`,
`fdb-fbc7`, `fdb-a751`. After one `fly machine update` the same three machines reported
`ee13`, `30cb` and a third — Fly reassigns MAC addresses across an update. The certificates
were bound to something that does not survive a restart, and all three machines refused to
start:

    a CA was given but no certificate for this machine's NIC (ee13)

That refusal is deliberate — the alternative is a machine silently adopting another
machine's identity, which makes peer verification meaningless — but it means the cluster is
down rather than degraded, and it will recur on every update.

Also worth recording: the first four NIC characters are `dead` on every Fly machine, their
OUI, so a prefix names nothing. Only the last octets vary, and those are the ones that churn.

## The question

What is the machine's identity?

1. **`FLY_MACHINE_ID`** — stable across updates, already used for `locality_zoneid`. Names
   would be `fdb-<machine id>`. Cheapest change; identity is Fly's to define.
2. **Issue at boot.** The machine generates a key, requests a certificate from OpenBao, and
   gets whatever name it is entitled to. Correct, and needs OpenBao reachable from the
   cluster plus an auth method — a deployment of its own.
3. **One certificate for the cluster**, not per machine, with the name fixed. Simplest;
   loses per-machine identity, so a compromised machine's certificate is the cluster's.

(2) is where this should end up, because it also answers renewal and rollover rather than
leaving them manual. (1) is worth taking first if TLS is wanted before that exists.

## Not yet done

Rollover, with its negative control: an unsigned certificate must be refused, or the rollover
demonstrated nothing. It cannot be written until the identity above is settled.

## Cost recorded for whoever changes this

There is no in-place migration from a plaintext FoundationDB cluster to a TLS one. A
coordinator's address is its identity, `:tls` is part of the address, and the coordinated
state on disk is written under the old one. The processes start, report healthy, speak TLS to
each other, and never reach quorum — `status` says only "Could not communicate with a quorum
of coordination servers", which reads like a network fault. `WEFT_FDB_RESET=1` exists for
this. Decide TLS before there is data worth keeping.
