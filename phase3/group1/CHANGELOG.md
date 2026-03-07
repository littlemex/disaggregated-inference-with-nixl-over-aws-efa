# Changelog - Phase 3 NIXL/EFA Investigation

All notable changes to Phase 3 investigation will be documented in this file.

## [2026-03-07] - INVESTIGATION: NIXL Request/Response Protocol Issues

### Added

- **vLLM-style TCP implementation** (`request_response_example_tcp.cpp`)
  - Descriptor list exchange via ZMQ/TCP instead of genNotif()
  - Notification reserved for transfer completion only
  - Attempted to avoid EFA connection establishment issue

- **TCP Control Channel implementation** (v2 of tcp implementation)
  - Complete control plane via ZMQ/TCP
  - Data plane via RDMA WRITE
  - Tested but RDMA transfer times out

- **Investigation breakthrough document** (`INVESTIGATION_BREAKTHROUGH_2026-03-07.md`)
  - Complete root cause analysis
  - 3 parallel Opus 4.6 agent findings
  - Technical solution attempts with results
  - Validation test results

- **Minimal libfabric test** (`/tmp/test_libfabric_senddata.cpp`)
  - Isolated reproduction of genNotif() issue
  - Confirmed "unacked CONNREQs in flight" error
  - Validated EFA RDM connection establishment timing

### Changed

- **README.md**: Added investigation status
- **confidential/README2.md**: Comprehensive investigation log updated

### Discovered

- **Root Cause 1**: genNotif() fi_senddata() called before EFA RDM connection established
  - First RDMA operation (READ_REQUEST) triggers CONNREQ/CONNRESP
  - genNotif() must wait until connection ready
  - vLLM avoids this by using separate TCP channel

- **Root Cause 2**: NIXL Request/Response protocol implementation incomplete
  - Control message methods declared in .cpp but not in .h files
  - `processRecvCompletion()` only handles NOTIFICATION messages
  - Control messages (READ_REQUEST/WRITE_REQUEST) fall through to error
  - `ControlMessageType` enum missing CONTROL_MESSAGE type
  - Both NIXL_READ and NIXL_WRITE operations fail

- **EFA Provider Behavior**:
  - fi_senddata() succeeds at API level (ret=0)
  - But SEND/RECV completions never arrive if connection not established
  - "Closing EP with unacked CONNREQs in flight" error on exit
  - CONNREQ/CONNRESP handshake never completes

### Status

- [BLOCKED] NIXL Request/Response protocol not usable in current state
- [IDENTIFIED] Multiple implementation layers incomplete
- [TESTED] TCP Control Channel approach also fails at RDMA layer

### Investigation Team

- Lead: Claude Opus 4.6
- vllm-nixl-comparison: Opus 4.6 (identified vLLM success pattern)
- efa-provider-investigator: Opus 4.6 (confirmed EFA support)
- libfabric-test-implementer: Opus 4.6 (created minimal reproduction)

### Git Commits

- `4f6b9dc` - feat: vLLM-style Request/Response with TCP descriptor exchange
- `10a50c0` - feat: Phase 3 investigation - genNotif root cause identified

---

## [2026-03-06] - Request/Response Protocol Investigation

### Added

- **Unit test implementation** (103/103 tests passing)
  - Local loopback test confirms NIXL Request/Response works
  - Validates notification mechanism implementation
  - Verifies Progress Thread operation

### Investigated

- **Progress Thread configuration**:
  - Confirmed 100us delay propagates to backend
  - Agent→Backend communication verified
  - CQ polling frequency validated

- **Notification mechanism**:
  - genNotif() implementation correct
  - xfer_id management (genNotif uses 0, RDMA uses >=1)
  - Control message handler registered properly

### Status

- Unit test: PASS (local environment)
- 2-node EFA: FAIL (genNotif() completion timeout)

---

## [2026-03-05] - Initial Request/Response Setup

### Added

- **Request/Response example** (`request_response_example.cpp`)
  - Producer/Consumer mode
  - Descriptor list exchange via genNotif()
  - NIXL_READ transfer with completion notification

- **Setup scripts**:
  - `compile_request_response.sh`
  - `run_request_response.sh`
  - `get_config.sh`

### Configured

- **NIXL Agent**:
  - Progress Thread enabled (100us delay)
  - Listener Thread enabled (p2p metadata exchange)
  - LIBFABRIC backend with EFA provider

- **Network**:
  - Producer: port 50100 (metadata + notification)
  - Consumer: connects to Producer private IP

### Documentation

- `NIXL_REQUEST_RESPONSE_SETUP.md`: Setup instructions
- `NIXL_REQUEST_RESPONSE_DESIGN.md`: Protocol design
- `QUICK_START_REQUEST_RESPONSE.md`: Quick start guide

---

## [2026-03-04] - Phase 3 Infrastructure Setup

### Deployed

- **AWS Stack**: `phase3-nixl-efa-dev-west-2`
  - Region: us-west-2
  - Instance Type: g7e.12xlarge (RTX PRO 6000 Blackwell 96GB x2)
  - EFA enabled

- **Node Configuration**:
  - Node1 (Producer): i-050ac7e7a9986ccc7 (172.31.2.221)
  - Node2 (Consumer): i-0634bbcbb9d65d4e3 (172.31.10.117)

### Verified

- **L1-Unified baseline**:
  - 12K context: P50 1396ms, P99 3178ms
  - 32K context: P50 1530ms, P99 6873ms
  - Input accuracy within 0.5% of target

---

## [2026-03-03] - Phase 3 Planning

### Designed

- **Experiment patterns**:
  - 12K-c1: Medium transfer (3.0 GB)
  - 32K-c1: Large transfer (8.0 GB)
  - 32K-c4: Concurrent transfer (8.0 GB x4)

- **Hypothesis**:
  - EFA (UCX+SRD) provides 20-50% TTFT improvement over TCP
  - Kernel bypass and low latency reduce KV transfer overhead

### Migration

- From Phase 2 (g6e.12xlarge, L40S, TP=4)
- To Phase 3 (g7e.12xlarge, Blackwell, TP=2)
- Focus: TCP vs EFA comparison (8 patterns vs 50 patterns)

---

## Key Metrics

### Investigation Time

- Phase 3 start: 2026-03-03
- Root cause identified: 2026-03-07 (4 days)
- Investigation method: 3 parallel Opus 4.6 agents

### Code Stats

- Total lines added: ~1500
- New files: 5
- Modified files: 3
- Test coverage: 103/103 unit tests passing

### Documentation

- Investigation docs: 3
- Setup guides: 3
- Analysis reports: 8 (confidential/)

---

## References

- **Repository**: `littlemex/disaggregated-inference-with-nixl-over-aws-efa`
- **Branch**: `phase3-g7e-efa-tcp-comparison`
- **Confidential**: All detailed logs in `phase3/group1/confidential/`

---

## Status Legend

- [BREAKTHROUGH]: Major discovery or solution
- [FIXED]: Issue resolved
- [DISCOVERED]: New finding
- [PENDING]: Work in progress
- [VALIDATED]: Confirmed working
