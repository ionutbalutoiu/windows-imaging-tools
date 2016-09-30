$ErrorActionPreference = "Stop"

$modules = Join-Path $env:SystemDrive "curtin\Modules"
$env:PSModulePath += ";$modules"

Import-Module powershell-yaml


function Set-InerfaceSubnets {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [object]$iface,
        [Parameter(Mandatory=$true)]
        [array]$subnets
    )
    PROCESS {
        # Interfaces that only have manual subnet types will be disabled
        # Interfaces that are meant to be part of bond ports will be enabled
        # while setting up the bond port
        $isManual = $true
        try { Remove-NetIPAddress -InterfaceIndex $iface.ifIndex -Confirm:$false } catch {}
        foreach($subnet in $subnets) {
            switch ($subnet["type"]) {
                "static" {
                    # we have at least one static subnet on this interface
                    $isManual = $false
                    $cidr = $subnet["address"]
                    if(!$cidr) {
                        continue
                    }
                    $ip, $netmask = $cidr.Split("/")
#                    try {
#                        Remove-NetIPAddress -IPAddress $ip `
#                                            -InterfaceIndex $iface.ifIndex `
#                                            -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
#                    } catch {}
                    $gateway = $subnet["gateway"]
                    Set-NetIPInterface -InterfaceIndex $iface.ifIndex -Dhcp Disabled
                    $nameservers = $subnet["dns_nameservers"]
                    New-NetIPAddress -IPAddress $ip `
                                     -PrefixLength $netmask `
                                     -InterfaceIndex $iface.ifIndex `
                                     -Confirm:$false | Out-Null
                    if($gateway) {
                        $hasRoute = Get-NetRoute -NextHop $gateway -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue
                        if(!$hasRoute) {
                            New-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop $gateway -InterfaceIndex $iface.ifIndex | Out-Null
                        }
                    }
                    if($nameservers -and $nameservers.Count -gt 0) {
                        Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses $nameservers -Confirm:$false | Out-Null
                    }
                }
                "dhcp4" {
                    # this is the default on windows. However, if the main adapter has DHCP enabled and there is an alias
                    # with static address assigned, then DHCP will be disabled on the interface as a whole
                    $isManual = $false
                    Set-NetIPInterface -InterfaceIndex $iface.ifIndex -Dhcp Enabled
                    continue
                }
            }
        }
        if($isManual) {
            Disable-NetAdapter -InputObject $iface -Confirm:$false | Out-Null
        }
    }
}

function Set-PhysicalAdapters {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[object]]$data
    )
    PROCESS {
        foreach($nic in $data) {
            $mac = $nic["mac_address"]
            if(!$mac) {
                continue
            }
            $iface = Get-NetAdapter | Where-Object {$_.MacAddress -eq ($mac -Replace ":","-")}
            if(!$iface) {
                continue
            }
            if($nic["name"]) {
                Rename-NetAdapter -InputObject $iface -NewName $nic["name"] -Confirm:$false | Out-Null
            }
            if($nic["mtu"]) {
                netsh interface ipv4 set subinterface $nic["name"] mtu=$nic["mtu"] store=persistent 2>&1 | Out-Null
            }
            if($nic["subnets"] -and $nic["subnets"].Count -gt 0){
                Set-InerfaceSubnets -iface $iface -Subnets $nic["subnets"] | Out-Null
            }
        }
    }
}

function Set-Nameservers {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[object]]$nameservers
    )
    PROCESS {
        $searchSuffix = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        $addresses = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
        foreach ($i in $nameservers) {
            if($i["search"] -and $i["search"].Count -gt 0){
                foreach($s in $i["search"]) {
                    $searchSuffix.Add($s)
                }
            }
            if($i["address"]){
                $addresses.Add($i["address"])
            }
        }
        if($searchSuffix.Count) {
            Set-DnsClientGlobalSetting -SuffixSearchList $searchSuffix -Confirm:$false | out-null
        }
        Set-DnsClientServerAddress * -ServerAddresses $addresses -Confirm:$false | out-null
    }
}

function Get-AdaptersFromList {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$ifaces
    )
    PROCESS {
        $interfaces = Get-NetAdapter | Where-Object {$_.Name -in $ifaces}
        if($interfaces.Count -ne $ifaces.Count) {
            # Something went wrong here, or maas sent wrong info
            return
        }
        return $interfaces
    }
}

function Set-BondInterfaces {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    PROCESS {
        $haveLbfo = Get-Command *NetLbfo*
        if(!$haveLbfo) {
            # most probably we are on a version of Nano that does not have support for this
            return
        }
        $required = @(
            "name",
            "mac_address",
            "bond_interfaces",
            "params"
        )
        foreach($bond in $data) {
            $team = try{ Get-NetLbfoTeam -Name $bond["name"] -ErrorAction SilentlyContinue } catch {}
            if($team) {
                continue
            }

            $missing = $false
            foreach ($req in $required) {
                if ($req -notin $bond.Keys) {
                    $missing = $true
                }
            }
            if($missing) {
                continue
            }
            # get interfaces
            $ifaces = Get-AdaptersFromList $bond["bond_interfaces"]
            if(!$ifaces) {
                continue
            }

            # Enable net adapters
            $ifaces | Enable-NetAdapter | Out-Null

            # get Primary iface
            $primary = $ifaces | Where-Object {$_.MacAddress -eq ($bond["mac_address"] -Replace ":","-")}

            # select proper mode. Default to Switch independent
            $mode = "SwitchIndependent"
            if ($bond["params"]["bond-mode"] -eq "802.3ad") {
                $mode = "Lacp"
            }

            $lbAlgo = "Dynamic"
            switch($bond["params"]["bond-xmit_hash_policy"]){
                "layer2" {
                    $lbAlgo = "MacAddresses"
                }
                "layer2+3" {
                    $lbAlgo = "IPAddresses"
                }
                "layer3+4" {
                    $lbAlgo = "TransportPorts"
                }
                default {
                    $lbAlgo = "Dynamic"
                }
            }
            New-NetLbfoTeam -Name $bond["name"] `
                            -TeamMembers $bond["bond_interfaces"] `
                            -TeamNicName $bond["name"] `
                            -TeamingMode $mode `
                            -LoadBalancingAlgorithm $lbAlgo `
                            -Confirm:$false | Out-Null
            Set-NetLbfoTeamMember -Name $primary.Name `
                                  -AdministrativeMode Active `
                                  -Confirm:$false | Out-Null
            $bondIface = Get-NetAdapter -Name $bond["name"] -ErrorAction SilentlyContinue
            if($bond["subnets"] -and $bond["subnets"].Count -gt 0 -and $bondIface){
                Set-InerfaceSubnets -iface $bondIface -Subnets $bond["subnets"] | Out-Null
            }
            if($bond["mtu"]) {
                netsh interface ipv4 set subinterface $bond["name"] mtu=$bond["mtu"] store=persistent 2>&1 | Out-Null
            }
        }
    }
}



function Set-VlanInterfaces {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [array]$Data
    )
    PROCESS {
        $haveLbfo = Get-Command *NetLbfo*
        if(!$haveLbfo) {
            # most probably we are on a version of Nano that does not have support for this
            return
        }
        foreach ($nic in $Data) {
            $link = $nic["vlan_link"]
            $name = $nic["name"]
            $id = $nic["vlan_id"]
            $linkIsBond = try { Get-NetLbfoTeam -Name $link -ErrorAction SilentlyContinue }catch {}
            if(!$linkIsBond) {
                # For now only VLANs set on bonds are supported
                continue
            }
            $exists = Get-NetLbfoTeamNic -Name $name -Team $link -ErrorAction SilentlyContinue
            if($exists) {
                continue
            }
            Add-NetLbfoTeamNic -Team $link -Name $name -VlanID $id -Confirm:$false | Out-Null

            # wait for NIC to come up
            $count = 0
            while($count -lt 30) {
                $iface = Get-NetAdapter $name -ErrorAction SilentlyContinue
                if($iface) {
                    break
                }
                $count += 1
                Start-Sleep 2
            }
            if($iface) {
                if($nic["subnets"] -and $nic["subnets"].Count -gt 0){
                    Set-InerfaceSubnets -iface $iface -Subnets $nic["subnets"]
                }
                if($nic["mtu"]) {
                    netsh interface ipv4 set subinterface $name mtu=$nic["mtu"] store=persistent 2>&1 | Out-Null
                }
            }
        }
    }
}

function Set-NetworkConfig {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Config
    )
    PROCESS {
        if(!(Test-Path $Config)) {
            Throw "Could not find config"
        }
        $data = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
        $cfg = [System.IO.File]::ReadAllText($Config) | ConvertFrom-Yaml
        foreach($i in $cfg["config"]) {
            if(!$i["type"]) {
                continue
            }
            $type = $i["type"]
            if(!$data[$type]){
                $data[$type] = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
            }
            $data[$type].Add($i)
        }

        # take care of the physical devices first
        if($data["physical"]) {
            Set-PhysicalAdapters $data["physical"]
        }
        # take care of bonds
        if($data["bond"]) {
            Set-BondInterfaces $data["bond"]
        }
        # Set VLAN links. NIC teams only for now
        if($data["vlan"]) {
            Set-VlanInterfaces $data["vlan"]
        }
        # set nameservers
        if($data["nameserver"]) {
            Set-Nameservers $data["nameserver"]
        }
    }
}

$config = (Join-Path $env:SystemDrive "network.json")
if((Test-Path $config)) {
    Set-NetworkConfig $config
}
