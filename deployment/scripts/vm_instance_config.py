#!/usr/bin/env python3
"""Generate and verify per-VM Terraform variable files (never edit shared tfvars)."""

import argparse
import ipaddress
import json
import re
from pathlib import Path


def vm_id_from_text(value: str) -> int:
    if not value.isdecimal() or str(int(value)) != value:
        raise ValueError("VM ID must be a canonical positive decimal number")
    vm_id = int(value)
    if not 100 <= vm_id <= 999999999:
        raise ValueError("VM ID must be between 100 and 999999999")
    return vm_id


def read_hcl_string(path: Path, name: str) -> str:
    text = path.read_text(encoding="utf-8")
    expression = rf'^[ \t]*{re.escape(name)}[ \t]*=[ \t]*"([^"\n]+)"'
    values = re.findall(expression, text, re.MULTILINE)
    if len(values) != 1:
        raise ValueError(f"Expected one quoted {name} in {path}")
    return values[0]


def network_settings(terraform_dir: Path):
    settings = terraform_dir / "terraform.tfvars"
    template = ipaddress.ip_interface(read_hcl_string(settings, "vm_ipv4_cidr"))
    gateway = ipaddress.ip_address(read_hcl_string(settings, "vm_gateway"))
    if not isinstance(template, ipaddress.IPv4Interface):
        raise ValueError("Only IPv4 VM networks are supported")
    if template.network.prefixlen != 24:
        raise ValueError("Two-argument deploy currently requires a /24 VM subnet")
    if gateway not in template.network:
        raise ValueError("Configured gateway is outside the VM subnet")
    return template.network, gateway


def instance_file(terraform_dir: Path, vm_id: int) -> Path:
    return terraform_dir / "instances" / f"vm-{vm_id}.tfvars.json"


def load_instance(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Not a Terraform variable object: {path}")
    return data


def check_unique_ip(terraform_dir: Path, vm_id: int, cidr: str) -> None:
    for other in (terraform_dir / "instances").glob("vm-*.tfvars.json"):
        if other == instance_file(terraform_dir, vm_id):
            continue
        if load_instance(other).get("vm_ipv4_cidr") == cidr:
            raise ValueError(f"{cidr} is already assigned in {other.name}")


def prepare(terraform_dir: Path, vm_id: int, octet_text: str) -> str:
    if not octet_text.isdecimal() or str(int(octet_text)) != octet_text:
        raise ValueError("The last IP octet must be a decimal integer")
    octet = int(octet_text)
    if not 2 <= octet <= 254:
        raise ValueError("The last IP octet must be between 2 and 254")
    network, gateway = network_settings(terraform_dir)
    address = ipaddress.IPv4Address(int(network.network_address) + octet)
    if address == gateway:
        raise ValueError("The requested VM address is the configured gateway")
    cidr = f"{address}/24"
    check_unique_ip(terraform_dir, vm_id, cidr)
    desired = {
        "create_vm": True,
        "vm_id": vm_id,
        "vm_name": f"job-market-ubuntu-{vm_id}",
        "vm_ipv4_cidr": cidr,
    }
    file = instance_file(terraform_dir, vm_id)
    if file.exists():
        if load_instance(file) != desired:
            raise ValueError(
                f"{file} already has different values; refusing to reassign this VM"
            )
    else:
        file.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation avoids silently replacing a concurrent or edited config.
        with file.open("x", encoding="utf-8") as output:
            json.dump(desired, output, indent=2)
            output.write("\n")
    return cidr


def verify(terraform_dir: Path, vm_id: int) -> str:
    file = instance_file(terraform_dir, vm_id)
    instance = load_instance(file)
    if (
        set(instance)
        != {"create_vm", "vm_id", "vm_name", "vm_ipv4_cidr"}
        or instance["create_vm"] is not True
        or instance["vm_id"] != vm_id
        or instance["vm_name"] != f"job-market-ubuntu-{vm_id}"
    ):
        raise ValueError(f"Invalid or mismatched instance configuration: {file}")
    network, gateway = network_settings(terraform_dir)
    interface = ipaddress.ip_interface(instance["vm_ipv4_cidr"])
    if (
        not isinstance(interface, ipaddress.IPv4Interface)
        or interface.network != network
        or interface.ip == gateway
        or interface.ip in {network.network_address, network.broadcast_address}
    ):
        raise ValueError(f"Instance address does not match the configured subnet: {file}")
    check_unique_ip(terraform_dir, vm_id, str(interface))
    return str(interface)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify"))
    parser.add_argument("terraform_dir", type=Path)
    parser.add_argument("vm_id")
    parser.add_argument("last_ip_octet", nargs="?")
    args = parser.parse_args()
    try:
        vm_id = vm_id_from_text(args.vm_id)
        if args.action == "prepare":
            if args.last_ip_octet is None:
                parser.error("prepare requires the last IP octet")
            result = prepare(args.terraform_dir, vm_id, args.last_ip_octet)
        else:
            if args.last_ip_octet is not None:
                parser.error("verify accepts only a VM ID")
            result = verify(args.terraform_dir, vm_id)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")
    print(result)


if __name__ == "__main__":
    main()
