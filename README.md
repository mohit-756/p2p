# P2P Migration Validator v8.0

## Overview

P2P Migration Validator is a read-only validation framework designed to compare Reference and Public Mule environments and generate a standardized migration assessment report.

The tool automates configuration validation activities that are typically performed manually using tools such as Beyond Compare and server reviews.

The validator produces:

- Engineering Validation Report (TXT)
- Executive HTML Dashboard
- Migration Readiness Assessment
- Reference vs Public Environment Comparison

## Key Validations

### MRT Discovery & Mapping

- Dynamic MRT Discovery
- Reference vs Public MRT Matching
- Unmatched MRT Detection
- Additional Running Mule Service Review

### Service Validation

- Service Status Verification
- Startup Mode Validation
- Service Account Validation

### Folder & Structure Validation

- Java8
- JConn_CPS
- Jconn_Automation
- JDA
- _SW
- Temp Directories

### Wrapper Configuration Validation

Validates and compares:

- InitMemory
- MaxMemory
- MetaspaceSize
- MaxMetaspaceSize
- JMX Configuration
- RMI Configuration
- Oracle JDBC Compliance
- Anypoint Gatekeeper
- Anypoint Base URI
- JavaTmpDir

### GGSVC Validation

Validates:

```text
-Dmule.deploy.applications=connect-config-service
```

for GGSVC wrappers.

### Environment Validation

- Java Version
- JAVA_HOME
- CPU Utilization
- Memory Utilization
- Disk Space

### ActiveMQ Validation

- ActiveMQ Installation
- ActiveMQ Listener Ports
- Suggested Console URL
- Environment Port Discovery

Supported Ports:

```text
Windows PROD : 11080
Windows QA   : 31080
Windows DEV  : 51080
Linux        : 51080
```

### Escalation Signature Analysis

Scans active logs for:

```text
OutOfMemoryError
BindException
AccessDeniedException
UnknownHostException
ConnectException
SSLException
ORA-
Permission denied
FileNotFoundException
```

## Features

✅ Read Only

✅ No File Changes

✅ No Service Restarts

✅ No Configuration Modifications

✅ Reference-Based Validation

✅ Executive HTML Dashboard

✅ Engineering Console Report

✅ Migration Summary

✅ Difference Detection

## Requirements

### PowerShell

```text
PowerShell 5.1 or later
```

### Permissions

- WinRM Access
- Remote PowerShell Access
- Read access to target servers

### Target Environment

Windows Mule Runtime Environments

## How To Run

Open PowerShell:

```powershell
cd C:\Path\To\Validator
powershell -STA -File .\P2PMigrationValidatorV80.ps1
```

Enter:

```text
Customer
INC (Optional)
Reference Server
Public Server
```

Select:

```text
Run Validation
```

## Outputs

### Text Report

```text
P2PValidation_v80_<Customer>_<INC>.txt
```

### HTML Dashboard

```text
P2PValidation_v80_<Customer>_<INC>.html
```

## Example Result

```text
VALIDATION PASSED

MRTs Matched            : 6/6
Wrappers Matched        : 6/6
Reference Differences   : 0
Escalation Signatures   : 0
```

or

```text
VALIDATION REVIEW REQUIRED

MRTs Matched            : 1/2
Wrappers Matched        : 0/1
Reference Differences   : 2
Escalation Signatures   : 0
```

## Typical Use Cases

- P2P Migration Validation
- Environment Handover Reviews
- Onboarding Validation
- Build Verification
- Reference vs Target Comparison
- Migration Readiness Assessment

## Notes

This tool provides automated configuration validation and comparison.

The validator does **not**:

- Execute business transactions
- Perform end-to-end testing
- Validate customer functionality
- Restart services
- Modify configurations

Use the generated reports as an engineering assessment and handover aid.

## Author

```text
Mohit Cheedella
P2P Migration Validator
Version 8.0
```
