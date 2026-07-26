#pragma once

//
//  cddc_shim.h
//
//  Declares private IOAVService types and functions for DDC/CI
//  communication on Apple Silicon Macs. These symbols are exported
//  by IOKit but have no public header.
//
//  Reference: DDC/CI spec (VESA MCCS v2.2), Apple IOKit IOAVService SPI.
//

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <CoreGraphics/CoreGraphics.h>

// IOAVService is an opaque CFType used to communicate with
// display AV services on Apple Silicon (DCPAVServiceProxy).
typedef CFTypeRef IOAVService;

// Create an IOAVService for the default display.
extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);

// Create an IOAVService bound to a specific io_service_t
// (a DCPAVServiceProxy entry from the IORegistry).
extern IOAVService IOAVServiceCreateWithService(
    CFAllocatorRef allocator,
    io_service_t service
);

// Write data to an I2C device via the AV service.
// chipAddress: 7-bit I2C address (0x37 for DDC displays).
// dataAddress: Sub-address / register (0x51 for DDC data).
// inputBuffer: Pointer to the data to write.
// inputBufferSize: Number of bytes to write.
extern IOReturn IOAVServiceWriteI2C(
    IOAVService service,
    uint32_t chipAddress,
    uint32_t dataAddress,
    void *inputBuffer,
    uint32_t inputBufferSize
);

// Read data from an I2C device via the AV service.
// chipAddress: 7-bit I2C address (0x37 for DDC displays).
// offset: Register offset to read from (0x51 for DDC data).
// outputBuffer: Pointer to buffer for the read data.
// outputBufferSize: Size of the output buffer.
extern IOReturn IOAVServiceReadI2C(
    IOAVService service,
    uint32_t chipAddress,
    uint32_t offset,
    void *outputBuffer,
    uint32_t outputBufferSize
);
