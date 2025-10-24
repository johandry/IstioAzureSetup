# Salt Master Configuration for Istio VM Setup
# This file contains the top-level Salt configuration

# Base state - executed during image build
base:
  '*':
    - image-build

# Target specific environments for boot-time configuration
'environment:production':
  - match: grain
  - boot-time

'environment:staging':
  - match: grain
  - boot-time

'environment:development':
  - match: grain
  - boot-time

# Target by role for specific configurations
'role:istio-vm':
  - match: grain
  - boot-time

# Target all VMs with istio-vm prefix
'istio-vm*':
  - boot-time