# Kubernetes Snarf Scripts

These scripts dump Kubernetes manifests while cleaning up runtime metadata and reducing output size.

## Script Options

### 1. `k8s-snarf-clean.sh` (Original Enhanced)
- **Size**: Medium to Large
- **Completeness**: High
- **Use Case**: When you need most data but want to remove runtime bloat

**What it does:**
- Removes runtime metadata (UIDs, timestamps, status, etc.)
- Redacts large base64 data in secrets (certificates, tokens)
- Simplifies CRD schemas but keeps structure
- Removes large base64 annotations

### 2. `k8s-snarf-balanced.sh` (Recommended)
- **Size**: Small to Medium  
- **Completeness**: High
- **Use Case**: Best balance between size and completeness

**What it does:**
- Removes runtime metadata
- Redacts secrets with data > 100 chars
- Removes verbose CRD descriptions but keeps structure
- Removes annotations > 200 chars

### 3. `k8s-snarf-minimal.sh` (Smallest)
- **Size**: Very Small
- **Completeness**: Medium
- **Use Case**: When you only need structure and basic config

**What it does:**
- Removes all runtime metadata
- Empties all secret data
- Simplifies CRDs to basic structure
- Removes all annotations
- Keeps only essential labels

## Usage

```bash
# Choose your preferred script
./k8s-snarf-clean.sh      # Original enhanced
./k8s-snarf-balanced.sh   # Recommended balance
./k8s-snarf-minimal.sh    # Minimal output
```

## Size Comparison

Based on typical k3s clusters:
- **Original**: ~2-5MB
- **Clean**: ~1-3MB  
- **Balanced**: ~200KB-1MB
- **Minimal**: ~50-200KB

## What Gets Removed

All scripts remove:
- `metadata.uid`
- `metadata.selfLink` 
- `metadata.resourceVersion`
- `metadata.generation`
- `metadata.creationTimestamp`
- `metadata.managedFields`
- `status` (runtime state)

## What Gets Redacted

**Balanced/Clean scripts:**
- Large base64 data in secrets (certificates, tokens)
- Large base64 annotations
- Verbose CRD descriptions

**Minimal script:**
- All secret data
- All annotations
- Most labels (keeps app labels)

## Requirements

- `kubectl` configured and working
- `yq` installed (for YAML processing)

## Output

Each script creates a directory with the same structure:
```
k8s-snapshot-{type}/
├── kube-system/
│   ├── deployments.yaml
│   ├── services.yaml
│   └── ...
├── default/
│   └── ...
└── ...
```

## Recommendation

Use **`k8s-snarf-balanced.sh`** for most use cases. It provides the best balance between having complete configuration information and manageable file sizes. 