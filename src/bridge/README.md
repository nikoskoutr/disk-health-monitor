# C11 IOKit & NVMe S.M.A.R.T. Bridge (`src/bridge/`)

This directory implements the low-level hardware telemetry bridge interfacing directly with macOS kernel frameworks (`IOKit.framework`, `DiskArbitration.framework`, `CoreFoundation.framework`, and `<sys/mount.h>`).

Implemented in C11 to interface with `IOCFPlugInInterface` vtables and raw binary log pages with deterministic memory layouts, zero runtime overhead, and full 128-bit counter fidelity.

---

## Files

### [`DiskHealthBridge.h`](DiskHealthBridge.h)
Declares the public C ABI structures and functions imported into Swift:
- **`DiskHardwareMetrics`**: Primary telemetry struct capturing:
  - **Topology**: `bsdName`, `vendorName`, `productName`, `productRevision`, `serialNumber`, `usbSerialNumber`, `interconnectType`, `protocolType`, `isInternal`, `isRemovable`, `linkSpeedBps`.
  - **NVMe S.M.A.R.T.**: `smartValid`, `criticalWarning`, `temperatureCelsius`, `temperatureKelvin`, `availableSpare`, `availableSpareThreshold`, `percentageUsed`, `dataUnitsRead`, `dataUnitsWritten`, `hostReadCommands`, `hostWriteCommands`, `controllerBusyTime`, `powerCycles`, `powerOnHours`, `unsafeShutdowns`, `mediaErrors`, `errorInfoLogEntries`.
  - **Driver Statistics**: `statsValid`, `bytesRead`, `bytesWritten`, `operationsRead`, `operationsWritten`, `errorsRead`, `errorsWritten`, `retriesRead`, `retriesWritten`, `totalTimeReadNs`, `totalTimeWriteNs`.
- **`DiskReadHardwareMetrics(const char *target, DiskHardwareMetrics *out)`**: Queries hardware metrics for an auto-detected drive, BSD identifier, mount path, or substring query.
- **`DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount)`**: Enumerates all attached block storage devices across the system.
- **`DiskFindMountForBlockDevice(const char *bsdName, char *outMount, size_t maxLen)`**: Resolves the mounted filesystem path for a block device using `IOObjectIsEqualTo` fast matching and APFS container resolution.
- **`DiskConvertNVMeTemperature(uint16_t tempRaw)`**: Converts 16-bit raw temperature to Celsius with Kelvin (`233K–423K`) and boundary validation.
- **`DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed)`**: Normalizes IOKit `Device Speed` enum codes (`0` to `5`) and raw bitrates to standardized bits per second.

### [`DiskHealthBridge.c`](DiskHealthBridge.c)
Implements hardware discovery and telemetry routines:
1. **APFS Physical Store Resolution**: Traverses parent services recursively (`findParentBlockStorageDeviceRecursive`) through `kIOServicePlane` to resolve synthesized APFS containers (`diskXsY` -> `AppleAPFSVolume` -> `AppleAPFSContainer`) down to the underlying physical `IOMedia`, `IONVMeController`, or `IOBlockStorageDevice`.
2. **128-Bit NVMe S.M.A.R.T. Decoding**: Reads NVMe Log Page `02h` (`NVMeSMARTData`) via `IONVMeSMARTUserClient`, decoding 16-byte little-endian counters (`nvmeLe128ToU64`) with saturation protection if upper 64 bits are non-zero.
3. **Interconnect & Link Speed Detection**: Traverses parent registry nodes to inspect `UsbLinkSpeed`, `LinkSpeed`, and `Device Speed` properties across `IOUSBHostDevice`, `AppleUSBXHCI`, SATA/AHCI, and PCIe controllers.
4. **Driver Statistics Extraction**: Extracts read/write operations, byte totals, I/O errors, retries, and cumulative latencies from `IOBlockStorageDriver` `Statistics` dictionaries.
