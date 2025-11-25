#!/usr/bin/env python3
"""
Command-line interface for Service Registry

This module provides CLI commands for interacting with the service registry
from shell scripts and terminal.
"""

import argparse
import json
import sys
from typing import Optional
from service_registry import ServiceRegistry, ServiceInfo, ServiceStatus


def register_command(args):
    """Register a new service"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    # Parse metadata if provided
    metadata = {}
    if args.metadata:
        try:
            metadata = json.loads(args.metadata)
        except json.JSONDecodeError:
            print("Error: metadata must be valid JSON", file=sys.stderr)
            return 1

    service = ServiceInfo(
        service_id=args.service_id,
        host=args.host,
        port=args.port,
        service_type=args.service_type,
        status=args.status,
        metadata=metadata
    )

    if registry.register_service(service):
        print(f"Successfully registered service: {args.service_id}")
        return 0
    else:
        print(f"Failed to register service: {args.service_id}", file=sys.stderr)
        return 1


def deregister_command(args):
    """Deregister a service"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    if registry.deregister_service(args.service_id):
        print(f"Successfully deregistered service: {args.service_id}")
        return 0
    else:
        print(f"Failed to deregister service: {args.service_id}", file=sys.stderr)
        return 1


def update_health_command(args):
    """Update service health status"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    status = ServiceStatus[args.status.upper()]

    # Parse metadata if provided
    metadata = None
    if args.metadata:
        try:
            metadata = json.loads(args.metadata)
        except json.JSONDecodeError:
            print("Error: metadata must be valid JSON", file=sys.stderr)
            return 1

    if registry.update_health(args.service_id, status, metadata):
        print(f"Successfully updated health for service: {args.service_id}")
        return 0
    else:
        print(f"Failed to update health for service: {args.service_id}", file=sys.stderr)
        return 1


def heartbeat_command(args):
    """Send heartbeat for a service"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    if registry.heartbeat(args.service_id):
        if not args.quiet:
            print(f"Heartbeat recorded for service: {args.service_id}")
        return 0
    else:
        print(f"Failed to record heartbeat for service: {args.service_id}", file=sys.stderr)
        return 1


def get_command(args):
    """Get service information"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    service = registry.get_service(args.service_id)
    if service:
        if args.format == 'json':
            output = {
                'service_id': service.service_id,
                'host': service.host,
                'port': service.port,
                'service_type': service.service_type,
                'status': service.status,
                'last_seen': service.last_seen,
                'metadata': service.metadata
            }
            print(json.dumps(output, indent=2))
        else:
            print(f"Service ID: {service.service_id}")
            print(f"Host: {service.host}")
            print(f"Port: {service.port}")
            print(f"Type: {service.service_type}")
            print(f"Status: {service.status}")
            print(f"Last Seen: {service.last_seen}")
            if service.metadata:
                print(f"Metadata: {json.dumps(service.metadata, indent=2)}")
        return 0
    else:
        print(f"Service not found: {args.service_id}", file=sys.stderr)
        return 1


def list_command(args):
    """List services"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    # Apply filters
    status_filter = None
    if args.status:
        status_filter = ServiceStatus[args.status.upper()]

    services = registry.list_services(
        service_type=args.service_type,
        status_filter=status_filter
    )

    if args.format == 'json':
        output = []
        for service in services:
            output.append({
                'service_id': service.service_id,
                'host': service.host,
                'port': service.port,
                'service_type': service.service_type,
                'status': service.status,
                'last_seen': service.last_seen,
                'metadata': service.metadata
            })
        print(json.dumps(output, indent=2))
    else:
        if not services:
            print("No services found")
        else:
            print(f"{'Service ID':<20} {'Host':<15} {'Port':<6} {'Type':<12} {'Status':<10}")
            print("-" * 75)
            for service in services:
                print(f"{service.service_id:<20} {service.host:<15} {service.port:<6} "
                      f"{service.service_type:<12} {service.status:<10}")

    return 0


def list_healthy_command(args):
    """List healthy services"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    services = registry.get_healthy_services(
        service_type=args.service_type,
        timeout_seconds=args.timeout
    )

    if args.format == 'json':
        output = []
        for service in services:
            output.append({
                'service_id': service.service_id,
                'host': service.host,
                'port': service.port,
                'service_type': service.service_type,
                'status': service.status,
                'last_seen': service.last_seen,
                'metadata': service.metadata
            })
        print(json.dumps(output, indent=2))
    else:
        if not services:
            print("No healthy services found")
        else:
            print(f"{'Service ID':<20} {'Host':<15} {'Port':<6} {'Type':<12}")
            print("-" * 60)
            for service in services:
                print(f"{service.service_id:<20} {service.host:<15} {service.port:<6} "
                      f"{service.service_type:<12}")

    return 0


def cleanup_command(args):
    """Cleanup stale services"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    removed = registry.cleanup_stale_services(timeout_seconds=args.timeout)
    print(f"Removed {removed} stale service(s)")
    return 0


def count_command(args):
    """Get service count"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    count = registry.get_service_count(service_type=args.service_type)
    print(count)
    return 0


def types_command(args):
    """List service types"""
    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    types = registry.get_service_types()
    if args.format == 'json':
        print(json.dumps(types, indent=2))
    else:
        for service_type in types:
            print(service_type)

    return 0


def clear_command(args):
    """Clear all service registry data"""
    if not args.confirm:
        response = input("Are you sure you want to clear all service registry data? (yes/no): ")
        if response.lower() != 'yes':
            print("Aborted")
            return 0

    registry = ServiceRegistry(
        redis_host=args.redis_host,
        redis_port=args.redis_port,
        redis_db=args.redis_db,
        key_prefix=args.key_prefix
    )

    if registry.clear_all():
        print("Successfully cleared all service registry data")
        return 0
    else:
        print("Failed to clear service registry data", file=sys.stderr)
        return 1


def main():
    parser = argparse.ArgumentParser(
        description='Service Registry CLI',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    # Global arguments
    parser.add_argument('--redis-host', default='localhost',
                       help='Redis host (default: localhost)')
    parser.add_argument('--redis-port', type=int, default=6379,
                       help='Redis port (default: 6379)')
    parser.add_argument('--redis-db', type=int, default=0,
                       help='Redis database number (default: 0)')
    parser.add_argument('--key-prefix', default='',
                       help='Prefix for all Redis keys (default: none)')

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Register command
    register_parser = subparsers.add_parser('register', help='Register a service')
    register_parser.add_argument('service_id', help='Service identifier')
    register_parser.add_argument('--host', required=True, help='Service host')
    register_parser.add_argument('--port', type=int, required=True, help='Service port')
    register_parser.add_argument('--service-type', required=True, help='Service type')
    register_parser.add_argument('--status', default='healthy',
                                choices=['healthy', 'unhealthy', 'starting', 'stopping', 'unknown'],
                                help='Initial status (default: healthy)')
    register_parser.add_argument('--metadata', help='Metadata as JSON string')
    register_parser.set_defaults(func=register_command)

    # Deregister command
    deregister_parser = subparsers.add_parser('deregister', help='Deregister a service')
    deregister_parser.add_argument('service_id', help='Service identifier')
    deregister_parser.set_defaults(func=deregister_command)

    # Update health command
    health_parser = subparsers.add_parser('update-health', help='Update service health')
    health_parser.add_argument('service_id', help='Service identifier')
    health_parser.add_argument('--status', required=True,
                              choices=['healthy', 'unhealthy', 'starting', 'stopping', 'unknown'],
                              help='New health status')
    health_parser.add_argument('--metadata', help='Additional metadata as JSON string')
    health_parser.set_defaults(func=update_health_command)

    # Heartbeat command
    heartbeat_parser = subparsers.add_parser('heartbeat', help='Send service heartbeat')
    heartbeat_parser.add_argument('service_id', help='Service identifier')
    heartbeat_parser.add_argument('--quiet', '-q', action='store_true',
                                 help='Suppress output')
    heartbeat_parser.set_defaults(func=heartbeat_command)

    # Get command
    get_parser = subparsers.add_parser('get', help='Get service information')
    get_parser.add_argument('service_id', help='Service identifier')
    get_parser.add_argument('--format', choices=['text', 'json'], default='text',
                           help='Output format (default: text)')
    get_parser.set_defaults(func=get_command)

    # List command
    list_parser = subparsers.add_parser('list', help='List services')
    list_parser.add_argument('--service-type', help='Filter by service type')
    list_parser.add_argument('--status',
                            choices=['healthy', 'unhealthy', 'starting', 'stopping', 'unknown'],
                            help='Filter by status')
    list_parser.add_argument('--format', choices=['text', 'json'], default='text',
                            help='Output format (default: text)')
    list_parser.set_defaults(func=list_command)

    # List healthy command
    healthy_parser = subparsers.add_parser('list-healthy', help='List healthy services')
    healthy_parser.add_argument('--service-type', help='Filter by service type')
    healthy_parser.add_argument('--timeout', type=int, default=30,
                               help='Heartbeat timeout in seconds (default: 30)')
    healthy_parser.add_argument('--format', choices=['text', 'json'], default='text',
                                help='Output format (default: text)')
    healthy_parser.set_defaults(func=list_healthy_command)

    # Cleanup command
    cleanup_parser = subparsers.add_parser('cleanup', help='Remove stale services')
    cleanup_parser.add_argument('--timeout', type=int, default=300,
                               help='Stale timeout in seconds (default: 300)')
    cleanup_parser.set_defaults(func=cleanup_command)

    # Count command
    count_parser = subparsers.add_parser('count', help='Get service count')
    count_parser.add_argument('--service-type', help='Filter by service type')
    count_parser.set_defaults(func=count_command)

    # Types command
    types_parser = subparsers.add_parser('types', help='List service types')
    types_parser.add_argument('--format', choices=['text', 'json'], default='text',
                             help='Output format (default: text)')
    types_parser.set_defaults(func=types_command)

    # Clear command
    clear_parser = subparsers.add_parser('clear', help='Clear all service registry data')
    clear_parser.add_argument('--confirm', '-y', action='store_true',
                             help='Skip confirmation prompt')
    clear_parser.set_defaults(func=clear_command)

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())

