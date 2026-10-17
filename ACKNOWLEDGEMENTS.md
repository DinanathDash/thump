# Acknowledgements

This project references low-level Apple Silicon SPU HID parameters discovered and documented by the following open-source project:

### nocnoc

- **Repository:** [https://github.com/shaircast/nocnoc](https://github.com/shaircast/nocnoc)
- **Author:** rayinclay / shaircast
- **Referenced Commit:** `00b283c2dbab1c975eca07cccbc4d147686db3b2` (Release `v1.0.3`)
- **License Status at Referenced Commit:** Declared as MIT in `README.md` (`## License \n MIT`), without a standalone LICENSE file present in the repository at that revision.

#### Specific Reference Details:
- Hardware driver identifiers and usage codes: `AppleSPUHIDDevice`, `AppleSPUHIDDriver`
- Vendor Usage Page: `0xFF00`
- Accelerometer Usage ID: `3`
- IMU Report packet byte length (`22`) and payload byte offsets (`6`, `10`, `14`)
