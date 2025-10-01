package services
package services

import (
	"context"
	"fmt"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v4"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/network/armnetwork/v2"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resources/armresources"
	"github.com/johandry/IstioAzureSetup/internal/config"
	"github.com/sirupsen/logrus"
)

// AzureService handles Azure operations
type AzureService struct {
	config             config.AzureConfig
	resourceClient     *armresources.Client
	computeClient      *armcompute.VirtualMachinesClient
	networkClient      *armnetwork.VirtualNetworksClient
	subnetClient       *armnetwork.SubnetsClient
	publicIPClient     *armnetwork.PublicIPAddressesClient
	nicClient          *armnetwork.InterfacesClient
	nsgClient          *armnetwork.SecurityGroupsClient
}

// VMRequest represents a VM creation request
type VMRequest struct {
	Name           string            `json:"name" binding:"required"`
	Size           string            `json:"size,omitempty"`
	Image          *VMImageRequest   `json:"image,omitempty"`
	Networking     *NetworkingRequest `json:"networking,omitempty"`
	CloudInitData  string            `json:"cloud_init_data,omitempty"`
	Tags           map[string]string `json:"tags,omitempty"`
	AdminUsername  string            `json:"admin_username,omitempty"`
	SSHPublicKey   string            `json:"ssh_public_key" binding:"required"`
}

// VMImageRequest represents VM image configuration
type VMImageRequest struct {
	Publisher string `json:"publisher,omitempty"`
	Offer     string `json:"offer,omitempty"`
	SKU       string `json:"sku,omitempty"`
	Version   string `json:"version,omitempty"`
}

// NetworkingRequest represents networking configuration
type NetworkingRequest struct {
	VNetName          string `json:"vnet_name,omitempty"`
	SubnetName        string `json:"subnet_name,omitempty"`
	SecurityGroupName string `json:"security_group_name,omitempty"`
	PublicIPEnabled   *bool  `json:"public_ip_enabled,omitempty"`
}

// VMInfo represents VM information
type VMInfo struct {
	Name           string            `json:"name"`
	ResourceGroup  string            `json:"resource_group"`
	Status         string            `json:"status"`
	Size           string            `json:"size"`
	PrivateIP      string            `json:"private_ip,omitempty"`
	PublicIP       string            `json:"public_ip,omitempty"`
	Tags           map[string]string `json:"tags,omitempty"`
	CreatedTime    time.Time         `json:"created_time"`
}

// NewAzureService creates a new Azure service instance
func NewAzureService(config config.AzureConfig) (*AzureService, error) {
	// Create credential using service principal
	cred, err := azidentity.NewClientSecretCredential(
		config.TenantID,
		config.ClientID,
		config.ClientSecret,
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create Azure credential: %w", err)
	}

	// Initialize clients
	resourceClient, err := armresources.NewClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource client: %w", err)
	}

	computeClient, err := armcompute.NewVirtualMachinesClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create compute client: %w", err)
	}

	networkClient, err := armnetwork.NewVirtualNetworksClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create network client: %w", err)
	}

	subnetClient, err := armnetwork.NewSubnetsClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create subnet client: %w", err)
	}

	publicIPClient, err := armnetwork.NewPublicIPAddressesClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create public IP client: %w", err)
	}

	nicClient, err := armnetwork.NewInterfacesClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create NIC client: %w", err)
	}

	nsgClient, err := armnetwork.NewSecurityGroupsClient(config.SubscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create NSG client: %w", err)
	}

	return &AzureService{
		config:         config,
		resourceClient: resourceClient,
		computeClient:  computeClient,
		networkClient:  networkClient,
		subnetClient:   subnetClient,
		publicIPClient: publicIPClient,
		nicClient:      nicClient,
		nsgClient:      nsgClient,
	}, nil
}

// CreateVM creates a new virtual machine
func (a *AzureService) CreateVM(ctx context.Context, request *VMRequest) (*VMInfo, error) {
	logrus.Infof("Creating VM: %s", request.Name)

	// Create or ensure resource group exists
	if err := a.ensureResourceGroup(ctx); err != nil {
		return nil, fmt.Errorf("failed to ensure resource group: %w", err)
	}

	// Create networking resources
	if err := a.ensureNetworking(ctx, request); err != nil {
		return nil, fmt.Errorf("failed to ensure networking: %w", err)
	}

	// Create network interface
	nicName := fmt.Sprintf("%s-nic", request.Name)
	if err := a.createNetworkInterface(ctx, request, nicName); err != nil {
		return nil, fmt.Errorf("failed to create network interface: %w", err)
	}

	// Create virtual machine
	if err := a.createVirtualMachine(ctx, request, nicName); err != nil {
		return nil, fmt.Errorf("failed to create virtual machine: %w", err)
	}

	// Get VM info
	return a.GetVM(ctx, request.Name)
}

// GetVM retrieves VM information
func (a *AzureService) GetVM(ctx context.Context, vmName string) (*VMInfo, error) {
	resp, err := a.computeClient.Get(ctx, a.config.ResourceGroupName, vmName, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to get VM: %w", err)
	}

	vm := resp.VirtualMachine
	
	// Get instance view for status
	instanceView, err := a.computeClient.InstanceView(ctx, a.config.ResourceGroupName, vmName, nil)
	if err != nil {
		logrus.Warnf("Failed to get VM instance view: %v", err)
	}

	status := "Unknown"
	if instanceView.VirtualMachine.InstanceView != nil && len(instanceView.VirtualMachine.InstanceView.Statuses) > 0 {
		for _, s := range instanceView.VirtualMachine.InstanceView.Statuses {
			if s.Code != nil && (*s.Code == "PowerState/running" || *s.Code == "PowerState/stopped") {
				status = *s.DisplayStatus
				break
			}
		}
	}

	vmInfo := &VMInfo{
		Name:          *vm.Name,
		ResourceGroup: a.config.ResourceGroupName,
		Status:        status,
		CreatedTime:   time.Now(), // This would typically come from ARM metadata
	}

	if vm.Properties != nil && vm.Properties.HardwareProfile != nil && vm.Properties.HardwareProfile.VMSize != nil {
		vmInfo.Size = string(*vm.Properties.HardwareProfile.VMSize)
	}

	if vm.Tags != nil {
		vmInfo.Tags = make(map[string]string)
		for k, v := range vm.Tags {
			if v != nil {
				vmInfo.Tags[k] = *v
			}
		}
	}

	// Get IP addresses
	if vm.Properties != nil && vm.Properties.NetworkProfile != nil && len(vm.Properties.NetworkProfile.NetworkInterfaces) > 0 {
		nicID := *vm.Properties.NetworkProfile.NetworkInterfaces[0].ID
		// Parse NIC name from ID
		// This is a simplified approach - in production, you'd parse the full ARM resource ID
		nicName := fmt.Sprintf("%s-nic", vmName)
		if ips, err := a.getNetworkInterfaceIPs(ctx, nicName); err == nil {
			vmInfo.PrivateIP = ips.PrivateIP
			vmInfo.PublicIP = ips.PublicIP
		}
	}

	return vmInfo, nil
}

// DeleteVM deletes a virtual machine and associated resources
func (a *AzureService) DeleteVM(ctx context.Context, vmName string) error {
	logrus.Infof("Deleting VM: %s", vmName)

	// Delete VM
	future, err := a.computeClient.BeginDelete(ctx, a.config.ResourceGroupName, vmName, nil)
	if err != nil {
		return fmt.Errorf("failed to start VM deletion: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to delete VM: %w", err)
	}

	// Delete associated NIC
	nicName := fmt.Sprintf("%s-nic", vmName)
	nicFuture, err := a.nicClient.BeginDelete(ctx, a.config.ResourceGroupName, nicName, nil)
	if err != nil {
		logrus.Warnf("Failed to start NIC deletion: %v", err)
	} else {
		if _, err := nicFuture.PollUntilDone(ctx, nil); err != nil {
			logrus.Warnf("Failed to delete NIC: %v", err)
		}
	}

	// Delete associated public IP
	publicIPName := fmt.Sprintf("%s-pip", vmName)
	pipFuture, err := a.publicIPClient.BeginDelete(ctx, a.config.ResourceGroupName, publicIPName, nil)
	if err != nil {
		logrus.Warnf("Failed to start public IP deletion: %v", err)
	} else {
		if _, err := pipFuture.PollUntilDone(ctx, nil); err != nil {
			logrus.Warnf("Failed to delete public IP: %v", err)
		}
	}

	return nil
}

// ListVMs lists all virtual machines in the resource group
func (a *AzureService) ListVMs(ctx context.Context) ([]*VMInfo, error) {
	pager := a.computeClient.NewListPager(a.config.ResourceGroupName, nil)
	var vms []*VMInfo

	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to list VMs: %w", err)
		}

		for _, vm := range page.Value {
			if vm.Name != nil {
				vmInfo, err := a.GetVM(ctx, *vm.Name)
				if err != nil {
					logrus.Warnf("Failed to get VM info for %s: %v", *vm.Name, err)
					continue
				}
				vms = append(vms, vmInfo)
			}
		}
	}

	return vms, nil
}

// Helper methods

func (a *AzureService) ensureResourceGroup(ctx context.Context) error {
	_, err := a.resourceClient.Get(ctx, a.config.ResourceGroupName, nil)
	if err != nil {
		// Resource group doesn't exist, create it
		_, err = a.resourceClient.CreateOrUpdate(ctx, a.config.ResourceGroupName, armresources.ResourceGroup{
			Location: to.Ptr(a.config.Location),
		}, nil)
		if err != nil {
			return fmt.Errorf("failed to create resource group: %w", err)
		}
		logrus.Infof("Created resource group: %s", a.config.ResourceGroupName)
	}
	return nil
}

func (a *AzureService) ensureNetworking(ctx context.Context, request *VMRequest) error {
	vnetName := a.config.ResourceGroupName + "-vnet"
	subnetName := "vm-subnet"
	nsgName := a.config.ResourceGroupName + "-nsg"

	if request.Networking != nil {
		if request.Networking.VNetName != "" {
			vnetName = request.Networking.VNetName
		}
		if request.Networking.SubnetName != "" {
			subnetName = request.Networking.SubnetName
		}
		if request.Networking.SecurityGroupName != "" {
			nsgName = request.Networking.SecurityGroupName
		}
	}

	// Create NSG first
	if err := a.createNetworkSecurityGroup(ctx, nsgName); err != nil {
		return err
	}

	// Create VNet and subnet
	if err := a.createVirtualNetwork(ctx, vnetName, subnetName, nsgName); err != nil {
		return err
	}

	return nil
}

func (a *AzureService) createNetworkSecurityGroup(ctx context.Context, nsgName string) error {
	// Check if NSG exists
	_, err := a.nsgClient.Get(ctx, a.config.ResourceGroupName, nsgName, nil)
	if err == nil {
		// NSG already exists
		return nil
	}

	nsgParams := armnetwork.SecurityGroup{
		Location: to.Ptr(a.config.Location),
		Properties: &armnetwork.SecurityGroupPropertiesFormat{
			SecurityRules: []*armnetwork.SecurityRule{
				{
					Name: to.Ptr("allow-ssh"),
					Properties: &armnetwork.SecurityRulePropertiesFormat{
						Protocol:                 to.Ptr(armnetwork.SecurityRuleProtocolTCP),
						SourcePortRange:          to.Ptr("*"),
						DestinationPortRange:     to.Ptr("22"),
						SourceAddressPrefix:      to.Ptr("*"),
						DestinationAddressPrefix: to.Ptr("*"),
						Access:                   to.Ptr(armnetwork.SecurityRuleAccessAllow),
						Priority:                 to.Ptr[int32](1001),
						Direction:                to.Ptr(armnetwork.SecurityRuleDirectionInbound),
					},
				},
				{
					Name: to.Ptr("allow-istio"),
					Properties: &armnetwork.SecurityRulePropertiesFormat{
						Protocol:                 to.Ptr(armnetwork.SecurityRuleProtocolTCP),
						SourcePortRange:          to.Ptr("*"),
						DestinationPortRange:     to.Ptr("15000-15010"),
						SourceAddressPrefix:      to.Ptr("*"),
						DestinationAddressPrefix: to.Ptr("*"),
						Access:                   to.Ptr(armnetwork.SecurityRuleAccessAllow),
						Priority:                 to.Ptr[int32](1002),
						Direction:                to.Ptr(armnetwork.SecurityRuleDirectionInbound),
					},
				},
			},
		},
	}

	future, err := a.nsgClient.BeginCreateOrUpdate(ctx, a.config.ResourceGroupName, nsgName, nsgParams, nil)
	if err != nil {
		return fmt.Errorf("failed to start NSG creation: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to create NSG: %w", err)
	}

	logrus.Infof("Created NSG: %s", nsgName)
	return nil
}

func (a *AzureService) createVirtualNetwork(ctx context.Context, vnetName, subnetName, nsgName string) error {
	// Check if VNet exists
	_, err := a.networkClient.Get(ctx, a.config.ResourceGroupName, vnetName, nil)
	if err == nil {
		// VNet already exists
		return nil
	}

	// Get NSG reference
	nsgResp, err := a.nsgClient.Get(ctx, a.config.ResourceGroupName, nsgName, nil)
	if err != nil {
		return fmt.Errorf("failed to get NSG reference: %w", err)
	}

	vnetParams := armnetwork.VirtualNetwork{
		Location: to.Ptr(a.config.Location),
		Properties: &armnetwork.VirtualNetworkPropertiesFormat{
			AddressSpace: &armnetwork.AddressSpace{
				AddressPrefixes: []*string{to.Ptr("10.0.0.0/16")},
			},
			Subnets: []*armnetwork.Subnet{
				{
					Name: to.Ptr(subnetName),
					Properties: &armnetwork.SubnetPropertiesFormat{
						AddressPrefix:        to.Ptr("10.0.1.0/24"),
						NetworkSecurityGroup: &nsgResp.SecurityGroup,
					},
				},
			},
		},
	}

	future, err := a.networkClient.BeginCreateOrUpdate(ctx, a.config.ResourceGroupName, vnetName, vnetParams, nil)
	if err != nil {
		return fmt.Errorf("failed to start VNet creation: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to create VNet: %w", err)
	}

	logrus.Infof("Created VNet: %s with subnet: %s", vnetName, subnetName)
	return nil
}

func (a *AzureService) createNetworkInterface(ctx context.Context, request *VMRequest, nicName string) error {
	vnetName := a.config.ResourceGroupName + "-vnet"
	subnetName := "vm-subnet"
	publicIPEnabled := true

	if request.Networking != nil {
		if request.Networking.VNetName != "" {
			vnetName = request.Networking.VNetName
		}
		if request.Networking.SubnetName != "" {
			subnetName = request.Networking.SubnetName
		}
		if request.Networking.PublicIPEnabled != nil {
			publicIPEnabled = *request.Networking.PublicIPEnabled
		}
	}

	// Get subnet
	subnetResp, err := a.subnetClient.Get(ctx, a.config.ResourceGroupName, vnetName, subnetName, nil)
	if err != nil {
		return fmt.Errorf("failed to get subnet: %w", err)
	}

	nicParams := armnetwork.Interface{
		Location: to.Ptr(a.config.Location),
		Properties: &armnetwork.InterfacePropertiesFormat{
			IPConfigurations: []*armnetwork.InterfaceIPConfiguration{
				{
					Name: to.Ptr("ipconfig1"),
					Properties: &armnetwork.InterfaceIPConfigurationPropertiesFormat{
						Subnet:                    &subnetResp.Subnet,
						PrivateIPAllocationMethod: to.Ptr(armnetwork.IPAllocationMethodDynamic),
					},
				},
			},
		},
	}

	// Create public IP if enabled
	if publicIPEnabled {
		publicIPName := fmt.Sprintf("%s-pip", request.Name)
		if err := a.createPublicIP(ctx, publicIPName); err != nil {
			return fmt.Errorf("failed to create public IP: %w", err)
		}

		// Get public IP reference
		pipResp, err := a.publicIPClient.Get(ctx, a.config.ResourceGroupName, publicIPName, nil)
		if err != nil {
			return fmt.Errorf("failed to get public IP reference: %w", err)
		}

		nicParams.Properties.IPConfigurations[0].Properties.PublicIPAddress = &pipResp.PublicIPAddress
	}

	future, err := a.nicClient.BeginCreateOrUpdate(ctx, a.config.ResourceGroupName, nicName, nicParams, nil)
	if err != nil {
		return fmt.Errorf("failed to start NIC creation: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to create NIC: %w", err)
	}

	logrus.Infof("Created NIC: %s", nicName)
	return nil
}

func (a *AzureService) createPublicIP(ctx context.Context, publicIPName string) error {
	pipParams := armnetwork.PublicIPAddress{
		Location: to.Ptr(a.config.Location),
		Properties: &armnetwork.PublicIPAddressPropertiesFormat{
			PublicIPAllocationMethod: to.Ptr(armnetwork.IPAllocationMethodDynamic),
		},
	}

	future, err := a.publicIPClient.BeginCreateOrUpdate(ctx, a.config.ResourceGroupName, publicIPName, pipParams, nil)
	if err != nil {
		return fmt.Errorf("failed to start public IP creation: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to create public IP: %w", err)
	}

	logrus.Infof("Created public IP: %s", publicIPName)
	return nil
}

func (a *AzureService) createVirtualMachine(ctx context.Context, request *VMRequest, nicName string) error {
	// Get NIC reference
	nicResp, err := a.nicClient.Get(ctx, a.config.ResourceGroupName, nicName, nil)
	if err != nil {
		return fmt.Errorf("failed to get NIC reference: %w", err)
	}

	// Set defaults
	size := "Standard_B2s"
	if request.Size != "" {
		size = request.Size
	}

	adminUsername := "azureuser"
	if request.AdminUsername != "" {
		adminUsername = request.AdminUsername
	}

	// Determine image reference
	imageRef := &armcompute.ImageReference{
		Publisher: to.Ptr("Canonical"),
		Offer:     to.Ptr("0001-com-ubuntu-server-focal"),
		SKU:       to.Ptr("20_04-lts-gen2"),
		Version:   to.Ptr("latest"),
	}

	if request.Image != nil {
		if request.Image.Publisher != "" {
			imageRef.Publisher = to.Ptr(request.Image.Publisher)
		}
		if request.Image.Offer != "" {
			imageRef.Offer = to.Ptr(request.Image.Offer)
		}
		if request.Image.SKU != "" {
			imageRef.SKU = to.Ptr(request.Image.SKU)
		}
		if request.Image.Version != "" {
			imageRef.Version = to.Ptr(request.Image.Version)
		}
	}

	vmParams := armcompute.VirtualMachine{
		Location: to.Ptr(a.config.Location),
		Properties: &armcompute.VirtualMachineProperties{
			HardwareProfile: &armcompute.HardwareProfile{
				VMSize: to.Ptr(armcompute.VirtualMachineSizeTypes(size)),
			},
			StorageProfile: &armcompute.StorageProfile{
				ImageReference: imageRef,
				OSDisk: &armcompute.OSDisk{
					CreateOption: to.Ptr(armcompute.DiskCreateOptionTypesFromImage),
					ManagedDisk: &armcompute.ManagedDiskParameters{
						StorageAccountType: to.Ptr(armcompute.StorageAccountTypesStandardLRS),
					},
				},
			},
			OSProfile: &armcompute.OSProfile{
				ComputerName:  to.Ptr(request.Name),
				AdminUsername: to.Ptr(adminUsername),
				LinuxConfiguration: &armcompute.LinuxConfiguration{
					DisablePasswordAuthentication: to.Ptr(true),
					SSH: &armcompute.SSHConfiguration{
						PublicKeys: []*armcompute.SSHPublicKey{
							{
								Path:    to.Ptr(fmt.Sprintf("/home/%s/.ssh/authorized_keys", adminUsername)),
								KeyData: to.Ptr(request.SSHPublicKey),
							},
						},
					},
				},
			},
			NetworkProfile: &armcompute.NetworkProfile{
				NetworkInterfaces: []*armcompute.NetworkInterfaceReference{
					{
						ID: nicResp.Interface.ID,
					},
				},
			},
		},
	}

	// Add cloud-init data if provided
	if request.CloudInitData != "" {
		vmParams.Properties.OSProfile.CustomData = to.Ptr(request.CloudInitData)
	}

	// Add tags
	if request.Tags != nil {
		vmParams.Tags = make(map[string]*string)
		for k, v := range request.Tags {
			vmParams.Tags[k] = to.Ptr(v)
		}
	}

	future, err := a.computeClient.BeginCreateOrUpdate(ctx, a.config.ResourceGroupName, request.Name, vmParams, nil)
	if err != nil {
		return fmt.Errorf("failed to start VM creation: %w", err)
	}

	if _, err := future.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("failed to create VM: %w", err)
	}

	logrus.Infof("Created VM: %s", request.Name)
	return nil
}

type NetworkIPs struct {
	PrivateIP string
	PublicIP  string
}

func (a *AzureService) getNetworkInterfaceIPs(ctx context.Context, nicName string) (*NetworkIPs, error) {
	resp, err := a.nicClient.Get(ctx, a.config.ResourceGroupName, nicName, nil)
	if err != nil {
		return nil, err
	}

	ips := &NetworkIPs{}

	if resp.Interface.Properties != nil && len(resp.Interface.Properties.IPConfigurations) > 0 {
		ipConfig := resp.Interface.Properties.IPConfigurations[0]
		if ipConfig.Properties != nil {
			if ipConfig.Properties.PrivateIPAddress != nil {
				ips.PrivateIP = *ipConfig.Properties.PrivateIPAddress
			}

			if ipConfig.Properties.PublicIPAddress != nil && ipConfig.Properties.PublicIPAddress.ID != nil {
				// Get public IP details
				// This is simplified - in production, parse the ARM resource ID properly
				publicIPName := fmt.Sprintf("%s-pip", nicName[:len(nicName)-4]) // Remove "-nic" suffix
				pipResp, err := a.publicIPClient.Get(ctx, a.config.ResourceGroupName, publicIPName, nil)
				if err == nil && pipResp.PublicIPAddress.Properties != nil && pipResp.PublicIPAddress.Properties.IPAddress != nil {
					ips.PublicIP = *pipResp.PublicIPAddress.Properties.IPAddress
				}
			}
		}
	}

	return ips, nil
}