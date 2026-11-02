
$vms = "controlnode", "node1", "node2"

foreach ($vm in $vms) {
    Copy-Item "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\base.vhdx" "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\$vm.vhdx"
    New-VM -Name $vm -Generation 2 -MemoryStartupBytes 2GB -VHDPath "C:\Users\Public\Documents\Hyper-V\Virtual hard disks\$vm.vhdx" -SwitchName VS1
    Set-VMFirmware -VMName $vm -EnableSecureBoot Off
}

