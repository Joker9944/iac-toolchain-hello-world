package main

import (
	"encoding/base64"
	"fmt"
	"strconv"

	"github.com/pulumi/pulumi-azure-native-sdk/authorization/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/containerregistry/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/containerservice/v3"
	"github.com/pulumi/pulumi-azure-native-sdk/resources/v3"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

const (
	roleAcrPull = "/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		// Location is automatically picket up by azure-native as configured in Pulumi.dev.yaml

		resourceGroup, err := resources.NewResourceGroup(ctx, "hello-toolchain-rg", nil)
		if err != nil {
			return err
		}

		registry, err := containerregistry.NewRegistry(ctx, "helloToolchainRegistry", &containerregistry.RegistryArgs{
			ResourceGroupName: resourceGroup.Name,
			Sku: &containerregistry.SkuArgs{
				Name: pulumi.String("Basic"),
			},
			AdminUserEnabled: pulumi.Bool(false),
		})
		if err != nil {
			return err
		}

		agentPoolCount, err := getConfigDefault(ctx, "agentPoolCount", 2)
		if err != nil {
			return err
		}

		vmSize, err := getConfigDefault(ctx, "vmSize", "Standard_D2s_v3")
		if err != nil {
			return err
		}

		cluster, err := containerservice.NewManagedCluster(ctx, "hello-toolchain-cluster", &containerservice.ManagedClusterArgs{
			ResourceGroupName: resourceGroup.Name,
			DnsPrefix:         pulumi.String("hello-toolchain"),
			Identity: &containerservice.ManagedClusterIdentityArgs{
				Type: containerservice.ResourceIdentityTypeSystemAssigned,
			},
			IngressProfile: &containerservice.ManagedClusterIngressProfileArgs{
				WebAppRouting: &containerservice.ManagedClusterIngressProfileWebAppRoutingArgs{
					Enabled: pulumi.Bool(true),
				},
			},
			AgentPoolProfiles: containerservice.ManagedClusterAgentPoolProfileArray{
				containerservice.ManagedClusterAgentPoolProfileArgs{
					Name:   pulumi.String("agentpool"),
					Count:  pulumi.Int(agentPoolCount),
					VmSize: pulumi.String(vmSize),
					OsType: containerservice.OSTypeLinux,
					Mode:   containerservice.AgentPoolModeSystem,
					Type:   containerservice.AgentPoolTypeVirtualMachineScaleSets,
				},
			},
		})
		if err != nil {
			return err
		}

		kubeletIdentityObjectId := cluster.IdentityProfile.ApplyT(
			func(profile map[string]containerservice.UserAssignedIdentityResponseV1) (string, error) {
				identity, ok := profile["kubeletidentity"]
				if !ok {
					return "", fmt.Errorf("kubelet identity not found in profile")
				}
				if identity.ObjectId == nil {
					return "", fmt.Errorf("kubelet identity principal ID is empty")
				}
				return *identity.ObjectId, nil
			},
		).(pulumi.StringOutput)

		clientConfig := authorization.GetClientConfigOutput(ctx)

		_, err = authorization.NewRoleAssignment(ctx, "hello-toolchain-acr-pull", &authorization.RoleAssignmentArgs{
			Scope: registry.ID(),
			RoleDefinitionId: pulumi.Sprintf("/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d",
				clientConfig.SubscriptionId()),
			PrincipalId:   kubeletIdentityObjectId,
			PrincipalType: authorization.PrincipalTypeServicePrincipal,
		})
		if err != nil {
			return err
		}

		resourceGroupName := resourceGroup.Name
		registryLoginServer := registry.LoginServer
		clusterName := cluster.Name

		creds := containerservice.ListManagedClusterUserCredentialsOutput(ctx, containerservice.ListManagedClusterUserCredentialsOutputArgs{
			ResourceGroupName: resourceGroupName,
			ResourceName:      clusterName,
		}, nil)

		kubeconfig := creds.Kubeconfigs().Index(pulumi.Int(0)).Value().ApplyT(func(encoded string) (string, error) {
			decoded, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil {
				return "", fmt.Errorf("failed to decode kubeconfig: %w", err)
			}
			return string(decoded), nil
		}).(pulumi.StringOutput)

		ctx.Export("resourceGroupName", resourceGroupName)
		ctx.Export("registryLoginServer", registryLoginServer)
		ctx.Export("clusterName", clusterName)
		ctx.Export("kubeconfig", kubeconfig)

		return nil
	})
}

func getConfigDefault[T string | int](ctx *pulumi.Context, key string, defaultValue T) (T, error) {
	raw, present := ctx.GetConfig(key)
	if !present {
		return defaultValue, nil
	}
	switch any(defaultValue).(type) {
	case int:
		n, err := strconv.Atoi(raw)
		if err != nil {
			return defaultValue, fmt.Errorf("config key %q is not a valid int: %w", key, err)
		}
		return any(n).(T), nil
	default:
		return any(raw).(T), nil
	}
}
