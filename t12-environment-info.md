# T12 WAL Benchmark — Environment Information

## cnpg1wal (us-east-1)

### Worker Node
| Field | Value |
|---|---|
| Instance name | ip-192-168-16-108.ec2.internal |
| Instance type | c6id.32xlarge |
| Region / AZ | us-east-1 / us-east-1e |
| Architecture | x86_64 (amd64) |
| OS image | Amazon Linux 2023.11.20260526 |
| Kernel | 6.12.88-119.157.amzn2023.x86_64 |
| Node created | 2026-06-01T21:14:02Z |
| Node Ready | 2026-06-01T21:14:12Z |

### Kubernetes
| Component | Version |
|---|---|
| Kubelet | v1.35.5-eks-3385e9b |
| EKS control plane | v1.35.4-eks-40737a8 |
| kubectl client | v1.35.0 |
| Container runtime | containerd 2.2.3 |

### CNPG & Plugins
| Component | Image |
|---|---|
| CNPG operator | ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1 |
| PostgreSQL | ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie |
| Barman Cloud plugin | ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.12.0 |
| Opera pgBackRest plugin | operasoftware/cnpg-plugin-pgbackrest:v0.6.0 |
| Dalibo pgBackRest plugin | registry.hub.docker.com/dalibo/cnpg-pgbackrest-controller:0.0.2 |

### Other Infrastructure
| Component | Version |
|---|---|
| cert-manager | v1.20.2 |
| AWS VPC CNI | v1.21.1-eksbuild.1 |
| CoreDNS | v1.13.2-eksbuild.4 |
| kube-proxy | v1.35.3-eksbuild.2 |
| metrics-server | v0.8.1-eksbuild.10 |

---

## cnpg4wal (us-west-2)

### Worker Node
| Field | Value |
|---|---|
| Instance name | ip-192-168-58-26.us-west-2.compute.internal |
| Instance type | c6id.32xlarge |
| Region / AZ | us-west-2 / us-west-2c |
| Architecture | x86_64 (amd64) |
| OS image | Amazon Linux 2023.11.20260526 |
| Kernel | 6.12.88-119.157.amzn2023.x86_64 |
| Node created | 2026-06-02T00:54:39Z |
| Node Ready | 2026-06-02T00:54:48Z |

### Kubernetes
| Component | Version |
|---|---|
| Kubelet | v1.35.5-eks-3385e9b |
| EKS control plane | v1.35.4-eks-40737a8 |
| kubectl client | v1.35.0 |
| Container runtime | containerd 2.2.3 |

### CNPG & Plugins
| Component | Image |
|---|---|
| CNPG operator | ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1 |
| PostgreSQL | ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie |
| Barman Cloud plugin | ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.12.0 |
| Opera pgBackRest plugin | operasoftware/cnpg-plugin-pgbackrest:v0.6.0 |
| Dalibo pgBackRest plugin | registry.hub.docker.com/dalibo/cnpg-pgbackrest-controller:0.0.2 |

### Other Infrastructure
| Component | Version |
|---|---|
| cert-manager | v1.20.2 |
| AWS VPC CNI | v1.21.1-eksbuild.1 |
| CoreDNS | v1.13.2-eksbuild.4 |
| kube-proxy | v1.35.3-eksbuild.2 |
| metrics-server | v0.8.1-eksbuild.10 |

---

## Notes

- Both clusters are identical in configuration — same instance type, same software versions, different regions.
- c6id.32xlarge: 128 vCPU, 256 GiB RAM, 2× 1.9 TB NVMe local SSD.
- The benchmark script does not pin a PostgreSQL image (`imageName` omitted); CNPG uses its operator-bundled default. Confirmed by running a cluster: `ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie` (PostgreSQL 18.1, Debian trixie, gcc 14.2.0).
- cnpg1wal node was provisioned ~3.7 hours before cnpg4wal.
- As of teardown (2026-06-03 14:34 UTC): cnpg1wal had been running ~41h 20m; cnpg4wal ~37h 39m.
