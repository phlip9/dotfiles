# secrets management

using rage + sops + sops-nix


## how this works

There's a top-level file `.sops.yaml` that declares all pubkeys and determines
which keys have access to which secrets files.

Groups of secrets are stored in a file like `nixos/omnara1/secrets.yaml`. The
`.sops.yaml` has a matching `creation_rules` regex that determines this secrets
file should be accessible by e.g. key A and key B.


## runbook: add/update host secret

Edit the secrets that should be accessible to a host:

```bash
$ sops nixos/omnara1/secrets.yaml
```


## runbook: new dev machine

Generate a "master" key. Dev machines have access to all secrets.

```bash
$ mkdir -p ~/.config/sops/age
$ rage-keygen -o ~/.config/sops/age/keys.txt
```

Add the pubkey to `.sops.yaml` and all secrets `creation_rules`:

```yaml
keys:
  - &phliptop-nitro age1t29pqpyt5wryjrryrhc8pc98ft6k3yn7r6yzx44yrkjmnw6kc9uqn43xpw
  - &omnara1 age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff
  - &build01 age173xhxpc7n9vwp84hy3gulfnn0zm9vwn4xce5wrvrs4kx3k8lefxsyhh2pu

creation_rules:
  - path_regex: nixos/omnara1/secrets.yaml$
    key_groups:
      - age:
        - *phliptop-nitro
        - *omnara1
  - path_regex: nixos/build01/secrets.yaml$
    key_groups:
      - age:
        - *phliptop-nitro
        - *build01
```

Encrypt all secrets to this new key:

```bash
$ just sops-updatekeys
```


## runbook: new server machine

Server machines only get access to their own secrets.
Get the ssh pubkey and convert it to an age pubkey:

```bash
$ ssh-keyscan -p 22022 omnara1.phlip9.com | ssh-to-age
age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff
```

Add this age pubkey to `.sops.yaml`:

```yaml
keys:
  - &phliptop-nitro age1t29pqpyt5wryjrryrhc8pc98ft6k3yn7r6yzx44yrkjmnw6kc9uqn43xpw
  - &omnara1 age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff

creation_rules:
  - path_regex: nixos/omnara1/secrets.yaml$
    key_groups:
      - age:
        - *phliptop-nitro
        - *omnara1
```

Encrypt all relevant secrets to this new key:

```bash
$ just sops-updatekeys
```
