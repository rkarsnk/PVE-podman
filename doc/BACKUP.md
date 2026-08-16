# バックアップ/マイグレーション手順書

最終更新: 2026-08-16

[SPEC.md](SPEC.md) 決定事項8の通り、永続データは以下2つのPodmanボリュームに
集約されている。ホスト入れ替え(マイグレーション)や定期バックアップは、
この2ボリュームのエクスポート/インポートで完結する。

| ボリューム名 | マウント先 | 内容 |
|---|---|---|
| `pve-var-lib-vz` | `/var/lib/vz` | VMディスク(qcow2)、ISO、テンプレート等 |
| `pve-cluster` | `/var/lib/pve-cluster` | pmxcfs(クラスタ設定DB) |

コンテナ名は本手順書では `pve` とする(SPEC.md 8節の実行例と同じ)。

## 1. バックアップ(エクスポート)

### 1.1 事前準備: コンテナ停止

pmxcfs(SQLiteベースの設定DB)やVMディスクの整合性を保つため、
エクスポート前にコンテナを止めることを推奨する。

```bash
podman stop pve
```

稼働中のままエクスポートすることも技術的には可能だが、書き込み中の
VMディスクやpmxcfs DBが不整合になるリスクがあるため、業務影響が
許容できるタイミングで停止すること。

### 1.2 ボリュームのエクスポート

```bash
mkdir -p /path/to/backup/$(date +%Y%m%d)
cd /path/to/backup/$(date +%Y%m%d)

podman volume export pve-var-lib-vz -o pve-var-lib-vz.tar
podman volume export pve-cluster    -o pve-cluster.tar
```

VMディスク量に比例して `pve-var-lib-vz.tar` が大きくなる。保存先の空き容量を
事前に確認すること。

### 1.3 コンテナの再開

```bash
podman start pve
```

## 2. マイグレーション(新ホストへの移行)

### 2.1 転送

`pve-var-lib-vz.tar` と `pve-cluster.tar` を新ホストへ転送する(`scp`、
外付けディスク等)。

### 2.2 新ホスト側の準備

新ホストで [SPEC.md](SPEC.md) 8節の手順に従い、macvlanネットワークの作成と
イメージビルドを先に済ませておく(コンテナはまだ起動しない)。

```bash
./host/setup-macvlan.sh
podman build -t pve-podman:latest .
```

### 2.3 ボリュームの作成とインポート

```bash
podman volume create pve-var-lib-vz
podman volume create pve-cluster

podman volume import pve-var-lib-vz pve-var-lib-vz.tar
podman volume import pve-cluster    pve-cluster.tar
```

### 2.4 コンテナ起動

SPEC.md 8節の `podman run` コマンドをそのまま実行する。新ホストの
`PVE_IP` / `PVE_GATEWAY` / `PARENT_IFACE` がLAN構成と一致していることを
確認すること(旧ホストと同一IPで運用を継続する場合は特に、旧ホストが
LAN上から完全に落ちてから起動すること。IP重複はネットワーク障害の原因になる)。

## 3. 定期バックアップの運用

現時点ではスクリプト化・自動化は行わず、上記1節の手順を手動または
簡易cronジョブ(systemd timer等)で定期実行する運用とする。自動化が
必要になった場合は本書を元にスクリプト化を検討する。

## 4. 注意事項

- `podman volume export`/`import` は Podman 4.2 以降が必要。ホストの
  Podmanバージョンを事前に確認すること(`podman --version`)。
- エクスポート/インポートはボリューム単位の完全コピーであり、増分バックアップ
  ではない。頻度が高い運用が必要な場合は、PVE標準の `vzdump`(VM単位の
  バックアップ)との併用を検討する。
- `pve-cluster` ボリュームにはクラスタ固有のノードID・証明書が含まれる。
  同一ホスト名/IPで別クラスタとして再構築したい場合(単純な設定引き継ぎでは
  なく作り直したい場合)は、このボリュームをインポートせず空のまま初回起動し、
  PVEの初期セットアップをやり直すこと。
