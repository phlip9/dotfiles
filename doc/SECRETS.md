# secrets management

using rage + sops + sops-nix


## how this works

There's a top-level file `.sops.yaml` that declares all pubkeys and determines
which keys have access to which secrets files.

Groups of secrets are stored in a file like `nixos/sauna/secrets.yaml`. The
`.sops.yaml` has a matching `creation_rules` regex that determines this secrets
file should be accessible by e.g. key A and key B.


## runbook: add/update host secret

Edit the secrets that should be accessible to a host:

```bash
$ sops nixos/sauna/secrets.yaml
```


## runbook: new dev machine master secret

Generate a "master" key. Dev machines have access to all secrets.

```bash
$ mkdir -p ~/.config/sops/age
$ rage-keygen -o ~/.config/sops/age/keys.txt
```

Add the pubkey to `.sops.yaml` and all secrets' `creation_rules`:

```yaml
keys:
  - &phliptop-nitro_age_master age1t29pqpyt5wryjrryrhc8pc98ft6k3yn7r6yzx44yrkjmnw6kc9uqn43xpw

  - &sauna_ssh_system age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff
  - &build01_ssh_system age173xhxpc7n9vwp84hy3gulfnn0zm9vwn4xce5wrvrs4kx3k8lefxsyhh2pu

creation_rules:
  - path_regex: nixos/sauna/secrets.yaml$
    key_groups:
      - age:
        - *phliptop-nitro_age_master

        - *sauna_ssh_system

  - path_regex: nixos/build01/secrets.yaml$
    key_groups:
      - age:
        - *phliptop-nitro_age_master

        - *build01_ssh_system
```

Encrypt all secrets to this new key:

```bash
$ just sops-updatekeys
```


## runbook: new desktop machine system secret

Desktop machines have no sshd host key, so they get a dedicated age key.
They only get access to their own secrets.

Generate the host key, on the machine:

```bash
$ sudo mkdir -p /var/lib/sops-nix
$ sudo rage-keygen -o /var/lib/sops-nix/key.txt
Public key: age1...
```

Add this age pubkey to `.sops.yaml`, w/ a rule for the host's secrets:

```yaml
keys:
  # ...
  - &phlipdesk_age_system age1...

creation_rules:
  - path_regex: nixos/phlipdesk/secrets.yaml$
    key_groups:
      - age:
        # ...
        - *phlipdesk_age_system
```

Point sops-nix at the key and the secrets file in the host config:

```nix
sops = {
  defaultSopsFile = ./secrets.yaml;
  age.keyFile = "/var/lib/sops-nix/key.txt";
  age.generateKey = true;
};
```

Create the secrets file:

```bash
$ sops nixos/phlipdesk/secrets.yaml
```


## runbook: new server machine system secret

Server machines only get access to their own secrets.
Get the ssh pubkey and convert it to an age pubkey:

```bash
$ ssh-keyscan -p 22022 sauna.phlip9.com | ssh-to-age
age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff
```

Add this age pubkey to `.sops.yaml`:

```yaml
keys:
  # ...
  - &sauna_ssh_system age1meufdn27h733757vg8swsfty5r2srghuxwerhkvm2swyr3ftrunqe7tqff

creation_rules:
  - path_regex: nixos/sauna/secrets.yaml$
    key_groups:
      - age:
        # ...
        - *sauna_ssh_system
```

Encrypt all relevant secrets to this new key:

```bash
$ just sops-updatekeys
```
