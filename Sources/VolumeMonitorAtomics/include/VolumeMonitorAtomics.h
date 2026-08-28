#ifndef VOLUME_MONITOR_ATOMICS_H
#define VOLUME_MONITOR_ATOMICS_H

#include <stdint.h>

void *vm_atomic_u32_create(uint32_t value);
void vm_atomic_u32_destroy(void *storage);
uint32_t vm_atomic_u32_load(const void *storage);
void vm_atomic_u32_store(void *storage, uint32_t value);

void *vm_atomic_u64_create(uint64_t value);
void vm_atomic_u64_destroy(void *storage);
uint64_t vm_atomic_u64_load(const void *storage);
void vm_atomic_u64_store(void *storage, uint64_t value);

#endif
