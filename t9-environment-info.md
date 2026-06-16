# T9 Data Benchmark — Environment Information

## cnpg11 (us-east-1)

### Worker Node
| Field | Value |
|---|---|
| Instance name | ip-192-168-58-166.ec2.internal |
| Instance type | c6id.32xlarge |
| Region / AZ | us-east-1 / us-east-1f |
| Architecture | x86_64 (amd64) |
| OS image | Amazon Linux 2023.11.20260526 |
| Kernel | 6.12.88-119.157.amzn2023.x86_64 |
| Node created | 2026-06-04T00:35:38Z |
| Node Ready | 2026-06-04T00:35:47Z |

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
| local-path-provisioner | v0.0.34 |

---

## cnpg12 (us-west-2)

### Worker Node
| Field | Value |
|---|---|
| Instance name | ip-192-168-45-226.us-west-2.compute.internal |
| Instance type | c6id.32xlarge |
| Region / AZ | us-west-2 / us-west-2c |
| Architecture | x86_64 (amd64) |
| OS image | Amazon Linux 2023.11.20260526 |
| Kernel | 6.12.88-119.157.amzn2023.x86_64 |
| Node created | 2026-06-04T00:33:47Z |
| Node Ready | 2026-06-04T00:33:56Z |

### Kubernetes
| Component | Version |
|---|---|
| Kubelet | v1.35.5-eks-3385e9b |
| EKS control plane | v1.35.5-eks-0247562 |
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
| local-path-provisioner | v0.0.34 |

---

## Notes

- Both clusters are identical in configuration — same instance type, same software versions, different regions.
- c6id.32xlarge: 128 vCPU, 256 GiB RAM, 2× 1.9 TB NVMe local SSD, 50 Gbps network.
- cnpg12 node was provisioned ~2 minutes before cnpg11 (both on 2026-06-04).
- cnpg11 and cnpg12 differ in EKS control plane patch version (eks-40737a8 vs eks-0247562); kubelet version is identical.
- The benchmark script does not pin a PostgreSQL image (`imageName` omitted); CNPG uses its operator-bundled default: `ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie`.
