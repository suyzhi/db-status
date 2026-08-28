#include "VolumeMonitorAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>

typedef struct {
    _Atomic(uint32_t) value;
} VMAtomicUInt32;

typedef struct {
    _Atomic(uint64_t) value;
} VMAtomicUInt64;

void *vm_atomic_u32_create(uint32_t value) {
    VMAtomicUInt32 *storage = malloc(sizeof(VMAtomicUInt32));
    if (storage != NULL) {
        atomic_init(&storage->value, value);
    }
    return storage;
}

void vm_atomic_u32_destroy(void *storage) {
    free(storage);
}

uint32_t vm_atomic_u32_load(const void *storage) {
    const VMAtomicUInt32 *atomic = storage;
    return atomic_load_explicit(&atomic->value, memory_order_relaxed);
}

void vm_atomic_u32_store(void *storage, uint32_t value) {
    VMAtomicUInt32 *atomic = storage;
    atomic_store_explicit(&atomic->value, value, memory_order_relaxed);
}

void *vm_atomic_u64_create(uint64_t value) {
    VMAtomicUInt64 *storage = malloc(sizeof(VMAtomicUInt64));
    if (storage != NULL) {
        atomic_init(&storage->value, value);
    }
    return storage;
}

void vm_atomic_u64_destroy(void *storage) {
    free(storage);
}

uint64_t vm_atomic_u64_load(const void *storage) {
    const VMAtomicUInt64 *atomic = storage;
    return atomic_load_explicit(&atomic->value, memory_order_acquire);
}

void vm_atomic_u64_store(void *storage, uint64_t value) {
    VMAtomicUInt64 *atomic = storage;
    atomic_store_explicit(&atomic->value, value, memory_order_release);
}
