# BGW620 WiFi / PWiFi Health Analyzer

Author: Reza Hassani

Version: V3.5.3

Read-only diagnostic tool for BGW620 gateways.

## Features

- WiFi Health Analysis
- WiFi7 / MLO Health
- ACS Diagnostics
- Backhaul / EasyMesh Validation
- CEVENTC Analysis
- Neighbor Health Checks
- Memory Health Analysis
- DNS / NAT Health Checks
- CSV Reporting
- LOG Reporting
- SCP Upload to BCEO

## Tested Environment

- BGW620
- BusyBox Linux
- Linux 5.15.x Firmware

## Output

The script generates:

- CSV report
- LOG report

and can upload results to:

/home/rh954n/BGW620/

using SCP.

## Notes

Read-only diagnostics.
## Version History

- V3.4  Initial release
- V3.5  Expanded diagnostics
- V3.5.1 SCP upload enhancements
- V3.5.2 Hardcoded /bin/scp upload fix
- V3.5.3 Enhanced on-screen summaries and usability improvements

No gateway configuration changes are performed.
