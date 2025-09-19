# VM Mesh Integration Flow Diagram

This document provides visual flow diagrams for the VM Mesh Integration process, covering both single VM and multiple VM scenarios.

## Overall Process Flow

```mermaid
flowchart TD
    A[Start: VM Mesh Integration] --> B[Prerequisites Check]
    B --> E[Part 1: Cluster-Side Setup]
    E --> F[Part 2: VM Creation with CloudInit]
    F --> G[Part 3: Post-VM Configuration]
    G --> H[Verification & Testing]
    H --> I[End: VMs Ready in Mesh]
    
    style A fill:#e1f5fe
    style I fill:#c8e6c9
```

## Part 1: Cluster-Side VM Mesh Integration Setup

```mermaid
flowchart TD
    A1[Part 1: Cluster-Side Setup] --> B1[Step 1: Verify Prerequisites]
    B1 --> B1a[kubectl cluster-info]
    B1 --> B1b[kubectl get pods -n istio-system]
    B1 --> B1c[istioctl version]
    
    B1a --> C1[Step 2: Configure Cluster Resources]
    B1b --> C1
    B1c --> C1
    
    C1 --> C1a[Create VM Workload Namespace]
    C1 --> C1b[Create Service Account]
    C1 --> C1c[Create WorkloadGroup]
    C1 --> C1d[Configure Service]
    C1 --> C1e[Set Up Authorization Policies]
    
    C1a --> D1[Step 3: Generate VM Configuration]
    C1b --> D1
    C1c --> D1
    C1d --> D1
    C1e --> D1
    
    D1 --> D1a[Create workspace directory]
    D1 --> D1b[Generate WorkloadGroup YAML]
    D1 --> D1c[Run istioctl x workload entry configure]
    D1 --> D1d[Generate certificates & config files]
    
    D1a --> E1[Step 4: Configure Traffic Management]
    D1b --> E1
    D1c --> E1
    D1d --> E1
    
    E1 --> E1a[Create VirtualService]
    E1 --> E1b[Create DestinationRule]
    
    E1a --> F1[Step 5: Verify Cluster Configuration]
    E1b --> F1
    
    F1 --> G1[Ready for VM Creation]
    
    style A1 fill:#e3f2fd
    style G1 fill:#c8e6c9
```

## Part 2: VM Creation and CloudInit Process

```mermaid
flowchart TD
    A2[Part 2: VM Creation] --> B2[Create the VM with CloudInit]
    B2 --> C2[Deploy VM with CloudInit YAML]

    C2 --> E2[CloudInit Process Execution]
    E2 --> E2a[Package Installation]
    E2 --> E2b[Directory Creation]
    E2 --> E2c[Script File Creation]
    E2 --> E2d[Firewall Configuration]
    E2 --> E2e[Istio Installation]
    
    E2a --> F2[VM Basic Setup Complete]
    E2b --> F2
    E2c --> F2
    E2d --> F2
    E2e --> F2
    
    F2 --> G2[Ready for Post-VM Configuration]
    
    style A2 fill:#e8f5e8
    style G2 fill:#c8e6c9
```

## Part 3: Post-VM Configuration

```mermaid
flowchart TD
    A3[Part 3: Post-VM Configuration] --> B3[Get VM IP Address]

    B3 --> E3[Transfer Configuration Files]
    E3 --> E3a[SSH to VMs]
    E3 --> E3b[Create vm-files directory]
    E3 --> E3c[Copy certificates and config files]
    
    E3a --> F3[Create WorkloadEntry Resources]
    E3b --> F3
    E3c --> F3
    
    F3 --> F3a[Create WorkloadEntry for each VM]

    F3a --> G3[Complete Mesh Setup on VMs]
    G3 --> G3a[SSH to VMs]
    G3 --> G3b[Run complete-mesh-setup script]
    
    G3a --> H3[Verification]
    G3b --> H3
    
    H3 --> I3[Ready for Testing]
    
    style A3 fill:#fff3e0
    style I3 fill:#c8e6c9
```

## VM Lifecycle Management Flow

```mermaid
flowchart TD
    A4[VM Lifecycle Management] --> B4{Operation Type?}
    
    B4 -->|Terminate VM| C4[VM Termination Process]
    B4 -->|Create New VM| D4[VM Creation Process]
    B4 -->|Mixed Operations| E4[Simultaneous Create/Terminate]
    B4 -->|Auto-Scaling| F4[Auto-Scaling Operations]
    
    C4 --> C4a[Identify VMs to Terminate]
    C4 --> C4b[Clean up WorkloadEntries]
    C4 --> C4c[Verify Shared Resources Intact]
    
    D4 --> D4a[Deploy New VMs]
    D4 --> D4b[Transfer Configuration Files]
    D4 --> D4c[Create WorkloadEntries]
    D4 --> D4d[Verify Integration]
    
    E4 --> E4a[Plan Mixed Operation]
    E4 --> E4b[Create New VMs First]
    E4 --> E4c[Verify New VMs Health]
    E4 --> E4d[Remove Old VMs]
    E4 --> E4e[Verify Service Continuity]
    
    F4 --> F4a{Scale Up or Down?}
    F4a -->|Up| F4b[Auto-Scale Up]
    F4a -->|Down| F4c[Auto-Scale Down]
    
    C4a --> G4[Operation Complete]
    C4b --> G4
    C4c --> G4
    D4a --> G4
    D4b --> G4
    D4c --> G4
    D4d --> G4
    E4a --> G4
    E4b --> G4
    E4c --> G4
    E4d --> G4
    E4e --> G4
    F4b --> G4
    F4c --> G4
    
    style A4 fill:#f3e5f5
    style G4 fill:#c8e6c9
```

## Verification and Testing Flow

```mermaid
flowchart TD
    A5[Verification & Testing] --> B5[Health Checks]
    B5 --> B5a[Run check-service script on VMs]
    B5 --> B5b[Check Istio service status]
    B5 --> B5c[Verify admin interface]
    
    B5a --> C5[Connectivity Tests]
    B5b --> C5
    B5c --> C5
    
    C5 --> C5a[Test cluster to VM connectivity]
    C5 --> C5b[Test VM to cluster connectivity]
    C5 --> C5c{Multiple VMs?}
    
    C5c -->|Yes| C5d[Test load balancing]
    C5c -->|No| D5[Monitor Istio Metrics]
    
    C5d --> D5
    
    D5 --> D5a[Check Istio proxy metrics]
    D5 --> D5b[Verify mTLS certificates]
    D5 --> D5c[Monitor service mesh traffic]
    
    D5a --> E5[Troubleshooting if needed]
    D5b --> E5
    D5c --> E5
    
    E5 --> E5a{Issues Found?}
    E5a -->|Yes| E5b[Debug and Fix Issues]
    E5a -->|No| F5[Integration Complete]
    
    E5b --> B5
    
    style A5 fill:#e0f2f1
    style F5 fill:#c8e6c9
```

## Decision Points and Branching

```mermaid
flowchart TD
    A6[VM Mesh Integration Decision Tree] --> B6{How many VMs?}
    
    B6 -->|Single VM| C6[Simple Single VM Flow]
    B6 -->|Multiple VMs| D6[Multiple VMs Flow]
    
    C6 --> C6a[Standard WorkloadEntry naming]
    C6 --> C6b[Simple verification steps]
    
    D6 --> D6a{Deployment Strategy?}
    D6a -->|All at Once| D6b[Bulk Creation/Termination]
    D6a -->|Rolling Update| D6c[Blue-Green Deployment]
    D6a -->|Auto-Scaling| D6d[Dynamic Scaling Operations]
    
    D6b --> E6[Batch Operations]
    D6c --> F6[Staged Operations]
    D6d --> G6[Automated Operations]
    
    E6 --> E6a[Use bulk scripts]
    E6 --> E6b[Parallel processing]
    
    F6 --> F6a[Create new VMs first]
    F6 --> F6b[Verify health before switching]
    F6 --> F6c[Remove old VMs last]
    
    G6 --> G6a[Monitor thresholds]
    G6 --> G6b[Automatic scaling scripts]
    G6 --> G6c[Health-based decisions]
    
    C6a --> H6[Success]
    C6b --> H6
    E6a --> H6
    E6b --> H6
    F6a --> H6
    F6b --> H6
    F6c --> H6
    G6a --> H6
    G6b --> H6
    G6c --> H6
    
    style A6 fill:#fce4ec
    style H6 fill:#c8e6c9
```

## Error Handling and Recovery Flow

```mermaid
flowchart TD
    A7[Error Scenarios] --> B7{Error Type?}
    
    B7 -->|VM Connection Failed| C7[VM Connectivity Issues]
    B7 -->|Istio Service Down| D7[Istio Service Issues]
    B7 -->|Certificate Problems| E7[Certificate Issues]
    B7 -->|Network Issues| F7[Network Configuration Issues]
    
    C7 --> C7a[Check VM status in Azure]
    C7 --> C7b[Verify SSH connectivity]
    C7 --> C7c[Check firewall rules]
    
    D7 --> D7a[Check Istio service status]
    D7 --> D7b[Restart Istio services]
    D7 --> D7c[Check service logs]
    
    E7 --> E7a[Verify certificate files]
    E7 --> E7b[Check certificate permissions]
    E7 --> E7c[Re-generate certificates if needed]
    
    F7 --> F7a[Check cluster connectivity]
    F7 --> F7b[Verify DNS resolution]
    F7 --> F7c[Test network routes]
    
    C7a --> G7[Apply Fix]
    C7b --> G7
    C7c --> G7
    D7a --> G7
    D7b --> G7
    D7c --> G7
    E7a --> G7
    E7b --> G7
    E7c --> G7
    F7a --> G7
    F7b --> G7
    F7c --> G7
    
    G7 --> H7[Retry Integration]
    H7 --> I7{Fixed?}
    I7 -->|Yes| J7[Continue with Process]
    I7 -->|No| K7[Escalate or Manual Intervention]
    
    style A7 fill:#ffebee
    style J7 fill:#c8e6c9
    style K7 fill:#ffcdd2
```

## Automation Scripts Workflow

```mermaid
flowchart TD
    A8[Automation Scripts] --> B8{Script Type?}
    
    B8 -->|VM Cleanup| C8[cleanup-multiple-vms.sh]
    B8 -->|VM Creation| D8[create-multiple-vm-workloadentries.sh]
    B8 -->|Health Check| E8[check-all-vms-health.sh]
    B8 -->|Auto-Scale Up| F8[auto-scale-up.sh]
    B8 -->|Auto-Scale Down| G8[auto-scale-down.sh]
    
    C8 --> C8a[Input: VM names or IPs]
    C8 --> C8b[Delete WorkloadEntries]
    C8 --> C8c[Verify cleanup]
    
    D8 --> D8a[Discover VMs in Azure]
    D8 --> D8b[Create WorkloadEntries]
    D8 --> D8c[Verify creation]
    
    E8 --> E8a[Get all VMs from mesh]
    E8 --> E8b[Test SSH connectivity]
    E8 --> E8c[Run health checks]
    E8 --> E8d[Test mesh connectivity]
    
    F8 --> F8a[Input: Scale count]
    F8 --> F8b[Find new VMs without entries]
    F8 --> F8c[Create WorkloadEntries]
    F8 --> F8d[Verify scaling]
    
    G8 --> G8a[Input: Scale down count]
    G8 --> G8b[Find auto-scaled VMs]
    G8 --> G8c[Remove WorkloadEntries]
    G8 --> G8d[Verify scaling]
    
    C8a --> H8[Script Complete]
    C8b --> H8
    C8c --> H8
    D8a --> H8
    D8b --> H8
    D8c --> H8
    E8a --> H8
    E8b --> H8
    E8c --> H8
    E8d --> H8
    F8a --> H8
    F8b --> H8
    F8c --> H8
    F8d --> H8
    G8a --> H8
    G8b --> H8
    G8c --> H8
    G8d --> H8
    
    style A8 fill:#e8eaf6
    style H8 fill:#c8e6c9
```

## Summary

This flow diagram represents the complete VM Mesh Integration process with the following key phases:

1. **Cluster-Side Setup**: Configure Kubernetes cluster resources for VM integration
2. **VM Creation**: Deploy VMs with CloudInit configuration
3. **Post-VM Configuration**: Transfer certificates and create WorkloadEntries
4. **Verification**: Test connectivity and mesh integration
5. **Lifecycle Management**: Handle VM termination, creation, and scaling
6. **Error Handling**: Troubleshoot and recover from issues
7. **Automation**: Use scripts for bulk operations and scaling

The diagrams support both single VM and multiple VM scenarios, with specific flows for complex operations like blue-green deployments, auto-scaling, and mixed create/terminate operations.
