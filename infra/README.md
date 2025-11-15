# HyperBEAM Infrastructure Assets

This folder groups the assets required to operate HyperBEAM both on a
single developer workstation and on the cloud. The
files were derived from the settings exposed by `hb_opts`,
`hb_store_opts`, and the deployment docs in `docs/run/`.

## Local sandbox (`scripts/run_local.sh`)

* Wraps the `erl` executable directly – no `rebar3 shell` – and adds every
  `_build/default/lib/*/ebin` directory to the code path.
* Generates an ephemeral config JSON under `infra/local/runtime`, pointing the
  LMDB store to `infra/local/runtime/data/cache-mainnet/lmdb`, and cleans all
  runtime artefacts when the node stops (set `HB_KEEP_RUNTIME=1` to skip).
* Respects `HB_PORT`, `HB_HOST`, `HB_MODE`, `HB_KEY`, `HB_LMDB_CAPACITY`,
  `HB_PRINT`, `HB_NODE_NAME`, and `HB_COOKIE`. The defaults match
  `infra/local/config.example.json`.
* Uses the repository’s `hyperbeam-key.json` as the operator key unless
  `HB_KEY` overrides it—replace that file with your actual Wander/JWK export
  before running.

Usage example:

```bash
HB_PORT=10000 \
HB_LMDB_CAPACITY=$((32 * 1024 * 1024 * 1024)) \
scripts/run_local.sh
```

## cloud configuration

* `infra/cloud/config.json` targets `/var/lib/hyperbeam` for data and sets
  a 250 TB LMDB map size (fits inside the 300 TB NVMe pool but under LMDB’s
  256 TB soft limit). Update `priv_key_location` plus `capacity` if you carve
  a different ZFS/LVM volume.
* `infra/cloud/systemd/hyperbeam.service` assumes a release installed in
  `/opt/hyperbeam` (produced by `rebar3 as prod release`). Copy the config to
  `/etc/hyperbeam/config.json`, the key to `/etc/hyperbeam/operator-wallet.json`,
  and run:

```bash
sudo useradd --system --home /var/lib/hyperbeam --shell /usr/sbin/nologin hyperbeam
sudo install -d -o hyperbeam -g hyperbeam /var/lib/hyperbeam/{cache-mainnet,cache-priv}
sudo install -o hyperbeam -g hyperbeam -m 600 hyperbeam-key.json /etc/hyperbeam/operator-wallet.json
sudo install -o root -g root -m 644 infra/cloud/config.json /etc/hyperbeam/config.json
sudo install -o root -g root -m 644 infra/cloud/systemd/hyperbeam.service /etc/systemd/system/hyperbeam.service
sudo systemctl daemon-reload
sudo systemctl enable --now hyperbeam.service
```

### Host prerequisites (from `docs/run/`)

1. OS packages: `build-essential cmake git pkg-config libssl-dev ncurses-dev curl jq`.
2. OTP 27 (use the Erlang Solutions repo or `asdf`).
3. `rebar3` (downloaded binary or package).
4. Rust toolchain (`rustup`, needed for WAMR and the SNP/elmdb NIFs).
5. Optional: Docker (only if you plan to containerize as per `Dockerfile`).

Provision the 1 TB RAM / 300 TB NVMe layout as follows:

* Create `/var/lib/hyperbeam/cache-mainnet{,/lmdb,/fs}` on the large array and
  mount it with `noatime` to reduce write amplification.
* Keep `/var/lib/hyperbeam/cache-priv` on encrypted storage; private device
  state and secrets land there.
* LMDB map size is controlled through `store_defaults.lmdb.capacity` (bytes).
  With 1 TB RAM the kernel can comfortably map 250 TB.

### Release workflow recap

1. `rebar3 as prod release` (add `rocksdb`/`http3`/`genesis_wasm` profiles
   before the `release` target if needed).
2. Copy `_build/prod/rel/hb` to `/opt/hyperbeam` and chown it to `hyperbeam`.
3. Place your key + config as shown above, then start the systemd service.
4. Confirm via `curl http://<public-ip>:10000/~meta@1.0/info` and monitor
   metrics on `/metrics` if `prometheus` stays enabled.

Refer back to `docs/run/configuring-your-machine.md` whenever you need to
extend `config.json` (e.g., routing tables, additional devices, trusted
signers, etc.).
