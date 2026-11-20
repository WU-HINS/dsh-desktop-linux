# 签名与校验

本仓库（WU-HINS fork）为每个 Release 的产物生成 GPG 分离签名。

## 签名密钥

| 项目 | 值 |
|---|---|
| UID | `WU-HINS DSH Linux CI <ci@wu-hins.dev>` |
| 类型 | RSA 4096，仅签名（SC） |
| 指纹 | `5B61 88F8 EFE3 E079 7AFE  4EBA 3082 DEB0 F806 E702` |
| 有效期 | 2028-11-19 |
| 公钥 | [`keys/PUBKEY.asc`](../keys/PUBKEY.asc)，同时随每个 Release 发布 |

私钥只存在于 CI 的仓库 Secret（`GPG_PRIVATE_KEY`）与维护者的离线备份中，不在仓库里。

## 校验产物

```bash
gpg --import PUBKEY.asc
gpg --verify deepseek-harness-*.AppImage.asc deepseek-harness-*.AppImage
sha256sum -c SHA256SUMS.txt
```

`SHA256SUMS.txt` 本身也有 `.asc` 签名，可以只信它一个：

```bash
gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt
```

## 说明

- 这是**社区构建的签名**，与 DeepSeek 官方签名无关；它只证明产物出自本仓库的流水线。
- 签名密钥由 CI 使用，口令为空；安全性依赖 GitHub Secret 的访问控制。
