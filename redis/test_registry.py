#!/usr/bin/env python3
"""
Unit tests for Service Registry

Run with: python3 test_registry.py
"""

import unittest
import time
from service_registry import ServiceRegistry, ServiceInfo, ServiceStatus


class TestServiceRegistry(unittest.TestCase):
    """Test cases for ServiceRegistry"""

    def setUp(self):
        """Set up test fixtures"""
        self.registry = ServiceRegistry(
            redis_host='localhost',
            redis_port=6379,
            key_prefix='test:'
        )
        # Clean up before each test
        self.registry.clear_all()

    def tearDown(self):
        """Clean up after each test"""
        self.registry.clear_all()

    def test_register_service(self):
        """Test service registration"""
        service = ServiceInfo(
            service_id="test-001",
            host="10.0.0.1",
            port=8000,
            service_type="test"
        )

        result = self.registry.register_service(service)
        self.assertTrue(result)

        # Verify service was registered
        retrieved = self.registry.get_service("test-001")
        self.assertIsNotNone(retrieved)
        self.assertEqual(retrieved.service_id, "test-001")
        self.assertEqual(retrieved.host, "10.0.0.1")
        self.assertEqual(retrieved.port, 8000)

    def test_deregister_service(self):
        """Test service deregistration"""
        service = ServiceInfo(
            service_id="test-002",
            host="10.0.0.2",
            port=8000,
            service_type="test"
        )

        self.registry.register_service(service)
        result = self.registry.deregister_service("test-002")
        self.assertTrue(result)

        # Verify service was removed
        retrieved = self.registry.get_service("test-002")
        self.assertIsNone(retrieved)

    def test_update_health(self):
        """Test health status update"""
        service = ServiceInfo(
            service_id="test-003",
            host="10.0.0.3",
            port=8000,
            service_type="test"
        )

        self.registry.register_service(service)

        # Update health
        result = self.registry.update_health(
            "test-003",
            ServiceStatus.UNHEALTHY,
            metadata={"error": "test error"}
        )
        self.assertTrue(result)

        # Verify update
        retrieved = self.registry.get_service("test-003")
        self.assertEqual(retrieved.status, ServiceStatus.UNHEALTHY.value)
        self.assertIn("error", retrieved.metadata)

    def test_heartbeat(self):
        """Test heartbeat functionality"""
        service = ServiceInfo(
            service_id="test-004",
            host="10.0.0.4",
            port=8000,
            service_type="test"
        )

        self.registry.register_service(service)
        initial = self.registry.get_service("test-004")

        time.sleep(0.1)

        # Send heartbeat
        self.registry.heartbeat("test-004")
        updated = self.registry.get_service("test-004")

        # Verify last_seen was updated
        self.assertGreater(updated.last_seen, initial.last_seen)

    def test_list_services(self):
        """Test listing services"""
        services = [
            ServiceInfo("test-005", "10.0.0.5", 8000, "type1"),
            ServiceInfo("test-006", "10.0.0.6", 8000, "type1"),
            ServiceInfo("test-007", "10.0.0.7", 8000, "type2"),
        ]

        for service in services:
            self.registry.register_service(service)

        # List all services
        all_services = self.registry.list_services()
        self.assertEqual(len(all_services), 3)

        # List by type
        type1_services = self.registry.list_services(service_type="type1")
        self.assertEqual(len(type1_services), 2)

    def test_get_healthy_services(self):
        """Test getting healthy services"""
        # Register healthy service
        service1 = ServiceInfo("test-008", "10.0.0.8", 8000, "test")
        self.registry.register_service(service1)

        # Register unhealthy service
        service2 = ServiceInfo("test-009", "10.0.0.9", 8000, "test")
        self.registry.register_service(service2)
        self.registry.update_health("test-009", ServiceStatus.UNHEALTHY)

        # Get healthy services
        healthy = self.registry.get_healthy_services(timeout_seconds=30)
        self.assertEqual(len(healthy), 1)
        self.assertEqual(healthy[0].service_id, "test-008")

    def test_cleanup_stale_services(self):
        """Test cleanup of stale services"""
        # Register a service
        service = ServiceInfo("test-010", "10.0.0.10", 8000, "test")
        self.registry.register_service(service)

        # Verify it exists
        self.assertEqual(self.registry.get_service_count(), 1)

        # Cleanup stale services (this one should be recent, so not removed)
        removed = self.registry.cleanup_stale_services(timeout_seconds=300)
        self.assertEqual(removed, 0)
        self.assertEqual(self.registry.get_service_count(), 1)

        # Cleanup with very short timeout (should remove it)
        removed = self.registry.cleanup_stale_services(timeout_seconds=0)
        self.assertEqual(removed, 1)
        self.assertEqual(self.registry.get_service_count(), 0)

    def test_get_service_count(self):
        """Test service count"""
        self.assertEqual(self.registry.get_service_count(), 0)

        # Register services
        services = [
            ServiceInfo("test-011", "10.0.0.11", 8000, "type1"),
            ServiceInfo("test-012", "10.0.0.12", 8000, "type1"),
            ServiceInfo("test-013", "10.0.0.13", 8000, "type2"),
        ]

        for service in services:
            self.registry.register_service(service)

        self.assertEqual(self.registry.get_service_count(), 3)
        self.assertEqual(self.registry.get_service_count(service_type="type1"), 2)
        self.assertEqual(self.registry.get_service_count(service_type="type2"), 1)

    def test_get_service_types(self):
        """Test getting service types"""
        services = [
            ServiceInfo("test-014", "10.0.0.14", 8000, "typeA"),
            ServiceInfo("test-015", "10.0.0.15", 8000, "typeB"),
            ServiceInfo("test-016", "10.0.0.16", 8000, "typeC"),
        ]

        for service in services:
            self.registry.register_service(service)

        types = self.registry.get_service_types()
        self.assertEqual(len(types), 3)
        self.assertIn("typeA", types)
        self.assertIn("typeB", types)
        self.assertIn("typeC", types)

    def test_metadata_persistence(self):
        """Test that metadata is properly stored and retrieved"""
        metadata = {
            "model": "llama-3-70b",
            "gpu": "A100",
            "gpu_memory": "80GB",
            "tags": ["production", "high-priority"]
        }

        service = ServiceInfo(
            service_id="test-017",
            host="10.0.0.17",
            port=8000,
            service_type="test",
            metadata=metadata
        )

        self.registry.register_service(service)
        retrieved = self.registry.get_service("test-017")

        self.assertEqual(retrieved.metadata["model"], "llama-3-70b")
        self.assertEqual(retrieved.metadata["gpu"], "A100")
        self.assertEqual(len(retrieved.metadata["tags"]), 2)


def main():
    """Run tests"""
    print("Running Service Registry Tests")
    print("=" * 60)
    print()

    # Check Redis connection
    try:
        import redis
        r = redis.Redis(host='localhost', port=6379)
        r.ping()
        print("✓ Redis connection successful")
        print()
    except Exception as e:
        print(f"✗ Cannot connect to Redis: {e}")
        print("  Please ensure Redis is running on localhost:6379")
        print()
        return 1

    # Run tests
    unittest.main(verbosity=2)


if __name__ == '__main__':
    main()

