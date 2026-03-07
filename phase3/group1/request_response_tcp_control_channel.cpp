/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 Amazon.com, Inc. and affiliates.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * @file request_response_example.cpp
 * @brief vLLM-style NIXL Request/Response protocol with TCP descriptor exchange
 *
 * This version uses TCP (ZMQ) for descriptor list exchange instead of genNotif(),
 * following the vLLM pattern where notification is reserved for transfer completion only.
 *
 * Key differences from genNotif version:
 *   1. Producer sends descriptor list via TCP (ZMQ REP socket, port+1)
 *   2. Consumer fetches descriptor list via TCP (ZMQ REQ socket)
 *   3. Notification (genNotif/getNotifs) is used ONLY for "TRANSFER_DONE" signal
 *
 * This avoids the fi_senddata connection establishment issue observed with genNotif().
 *
 * Usage:
 *   # Producer (Node1 - has data)
 *   ./request_response_example --mode producer --port 50100
 *
 *   # Consumer (Node2 - reads data)
 *   ./request_response_example --mode consumer --producer-ip 172.31.2.221 --port 50100
 */

#include <iostream>
#include <cstring>
#include <string>
#include <chrono>
#include <thread>
#include <vector>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

// ZMQ for descriptor exchange
#include <zmq.h>

// NIXL includes
#include "nixl.h"
#include "nixl_descriptors.h"
#include "serdes/serdes.h"

// Constants
static const char *PRODUCER_NAME = "producer";
static const char *CONSUMER_NAME = "consumer";

static const int NUM_DESCRIPTORS = 8;
static const size_t DESC_SIZE = 1024 * 1024;  // 1 MB per descriptor
static const size_t TOTAL_SIZE = NUM_DESCRIPTORS * DESC_SIZE;
static const int TIMEOUT_SEC = 60;

// Configuration
struct Config {
    std::string mode;          // "producer" or "consumer"
    std::string producer_ip;   // Producer IP (for Consumer)
    int port;                  // NIXL listener port
    std::string backend;       // Backend type (default: LIBFABRIC)
};

// Helper: Parse command line arguments
Config parseArgs(int argc, char *argv[]) {
    Config cfg;
    cfg.port = 50100;
    cfg.backend = "LIBFABRIC";

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            cfg.mode = argv[++i];
        } else if (arg == "--producer-ip" && i + 1 < argc) {
            cfg.producer_ip = argv[++i];
        } else if (arg == "--port" && i + 1 < argc) {
            cfg.port = std::atoi(argv[++i]);
        } else if (arg == "--backend" && i + 1 < argc) {
            cfg.backend = argv[++i];
        }
    }

    if (cfg.mode != "producer" && cfg.mode != "consumer") {
        std::cerr << "Error: --mode must be 'producer' or 'consumer'\n";
        std::exit(1);
    }
    if (cfg.mode == "consumer" && cfg.producer_ip.empty()) {
        std::cerr << "Error: --producer-ip required for consumer mode\n";
        std::exit(1);
    }

    return cfg;
}

// Helper: Exit on NIXL failure
void nixl_exit_on_failure(nixl_status_t st, const char *msg, const char *agent_name) {
    if (st != NIXL_SUCCESS) {
        std::cerr << "[" << agent_name << "] ERROR: " << msg << " (status=" << st << ")\n";
        std::exit(1);
    }
}

// Helper: Fill producer buffer with known pattern
void fillProducerData(uint8_t *buffer, int num_descs) {
    for (int i = 0; i < num_descs; i++) {
        uint8_t *desc_start = buffer + i * DESC_SIZE;
        // Pattern: DESC{i}:byte_offset
        char pattern[32];
        snprintf(pattern, sizeof(pattern), "DESC%d:", i);
        size_t pattern_len = strlen(pattern);

        for (size_t offset = 0; offset < DESC_SIZE; offset++) {
            if (offset < pattern_len) {
                desc_start[offset] = pattern[offset];
            } else {
                desc_start[offset] = static_cast<uint8_t>(offset & 0xFF);
            }
        }
    }
}

// Helper: Verify consumer buffer matches expected pattern
bool verifyConsumerData(const uint8_t *buffer, int num_descs) {
    bool all_ok = true;
    for (int i = 0; i < num_descs; i++) {
        const uint8_t *desc_start = buffer + i * DESC_SIZE;
        char expected_pattern[32];
        snprintf(expected_pattern, sizeof(expected_pattern), "DESC%d:", i);
        size_t pattern_len = strlen(expected_pattern);

        // Check pattern prefix
        if (std::memcmp(desc_start, expected_pattern, pattern_len) != 0) {
            std::cerr << "[Consumer] Descriptor " << i << " pattern mismatch\n";
            all_ok = false;
            continue;
        }

        // Check byte sequence
        for (size_t offset = pattern_len; offset < DESC_SIZE; offset++) {
            uint8_t expected = static_cast<uint8_t>(offset & 0xFF);
            if (desc_start[offset] != expected) {
                std::cerr << "[Consumer] Descriptor " << i << " byte mismatch at offset "
                          << offset << ": expected=" << (int)expected
                          << " got=" << (int)desc_start[offset] << "\n";
                all_ok = false;
                break;
            }
        }
    }
    return all_ok;
}

//=============================================================================
// PRODUCER
//=============================================================================

int runProducer(const Config &cfg) {
    // Unbuffered I/O for immediate log output
    std::cout << std::unitbuf;
    std::cerr << std::unitbuf;
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    std::cout << "\n============================================\n"
              << "  Request/Response Example (vLLM-style)\n"
              << "  Mode: PRODUCER\n"
              << "  Port: " << cfg.port << "\n"
              << "  Descriptor exchange: TCP (port+" << 1 << ")\n"
              << "  Backend: " << cfg.backend << "\n"
              << "  Transfer: " << NUM_DESCRIPTORS << " x " << DESC_SIZE
              << " = " << TOTAL_SIZE << " bytes\n"
              << "============================================\n\n";

    nixl_status_t st;

    // 1. Initialize NIXL agent
    nixlAgentConfig agentCfg(
        true,       // use_prog_thread
        true,       // use_listen_thread
        cfg.port,   // listener port
        nixl_thread_sync_t::NIXL_THREAD_SYNC_DEFAULT,
        1,          // num_workers
        100         // pthr_delay_us (for notification progress)
    );
    nixlAgent agent(PRODUCER_NAME, agentCfg);
    std::cout << "[Producer] Agent initialized (port " << cfg.port << ")\n";

    // 2. Create backend
    nixl_b_params_t backendParams;
    nixl_mem_list_t supportedMems;
    st = agent.getPluginParams(cfg.backend, supportedMems, backendParams);
    nixl_exit_on_failure(st, "Failed to get plugin params", PRODUCER_NAME);

    nixlBackendH *bknd = nullptr;
    st = agent.createBackend(cfg.backend, backendParams, bknd);
    nixl_exit_on_failure(st, "Failed to create backend", PRODUCER_NAME);
    std::cout << "[Producer] " << cfg.backend << " backend created\n";

    nixl_opt_args_t extraParams;
    extraParams.backends.push_back(bknd);

    // 3. Allocate and fill buffer
    std::vector<uint8_t> buffer(TOTAL_SIZE);
    fillProducerData(buffer.data(), NUM_DESCRIPTORS);
    std::cout << "[Producer] Buffer filled (" << NUM_DESCRIPTORS << " descriptors)\n";

    // 4. Register memory
    nixl_reg_dlist_t regDescs(DRAM_SEG);
    for (int i = 0; i < NUM_DESCRIPTORS; i++) {
        nixlBlobDesc blobDesc;
        blobDesc.addr  = reinterpret_cast<uintptr_t>(buffer.data() + i * DESC_SIZE);
        blobDesc.len   = DESC_SIZE;
        blobDesc.devId = 0;
        regDescs.addDesc(blobDesc);
    }

    st = agent.registerMem(regDescs, &extraParams);
    nixl_exit_on_failure(st, "Failed to register memory", PRODUCER_NAME);
    std::cout << "[Producer] Memory registered\n";

    // 5. Wait for Consumer metadata (listener thread handles incoming connections)
    std::cout << "[Producer] Waiting for Consumer to connect...\n";
    nixl_xfer_dlist_t emptyDescs(DRAM_SEG);
    bool consumerReady = false;
    auto startTime = std::chrono::steady_clock::now();

    while (!consumerReady) {
        consumerReady = (agent.checkRemoteMD(CONSUMER_NAME, emptyDescs) == NIXL_SUCCESS);

        auto elapsed = std::chrono::steady_clock::now() - startTime;
        if (std::chrono::duration_cast<std::chrono::seconds>(elapsed).count() > TIMEOUT_SEC) {
            std::cerr << "[Producer] Timeout waiting for Consumer metadata\n";
            return 1;
        }
        if (!consumerReady) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    std::cout << "[Producer] Consumer metadata received\n";

    // 7. Serialize descriptor list for TCP exchange
    nixl_xfer_dlist_t xferDescs = regDescs.trim();
    nixlSerDes serdes;
    st = xferDescs.serialize(&serdes);
    nixl_exit_on_failure(st, "Failed to serialize descriptor list", PRODUCER_NAME);
    std::string descListMsg = serdes.exportStr();
    std::cout << "[Producer] Descriptor list serialized (" << descListMsg.size() << " bytes)\n";

    // 8. Start ZMQ REP server for descriptor exchange (port+1)
    std::cout << "[Producer] Starting ZMQ REP server for descriptor exchange (port "
              << (cfg.port + 1) << ")...\n";
    void *zmq_ctx = zmq_ctx_new();
    void *zmq_sock = zmq_socket(zmq_ctx, ZMQ_REP);
    std::string zmq_endpoint = "tcp://*:" + std::to_string(cfg.port + 1);
    int rc = zmq_bind(zmq_sock, zmq_endpoint.c_str());
    if (rc != 0) {
        std::cerr << "[Producer] Failed to bind ZMQ socket: " << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }
    std::cout << "[Producer] ZMQ server listening on " << zmq_endpoint << "\n";

    // 9. Wait for Consumer to request descriptor list
    std::cout << "[Producer] Waiting for Consumer descriptor request...\n";
    char recv_buf[16];
    int recv_size = zmq_recv(zmq_sock, recv_buf, sizeof(recv_buf), 0);
    if (recv_size < 0) {
        std::cerr << "[Producer] Failed to receive descriptor request: "
                  << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }
    std::cout << "[Producer] Received descriptor request from Consumer\n";

    // 10. Send descriptor list via ZMQ
    rc = zmq_send(zmq_sock, descListMsg.data(), descListMsg.size(), 0);
    if (rc < 0) {
        std::cerr << "[Producer] Failed to send descriptor list: "
                  << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }
    std::cout << "[Producer] Descriptor list sent to Consumer (" << descListMsg.size() << " bytes)\n";

    // 11. Wait for START_TRANSFER request with Consumer's descriptor list via ZMQ
    std::cout << "[Producer] Waiting for START_TRANSFER request...\n";
    char start_buf[1024 * 1024];  // 1 MB buffer
    recv_size = zmq_recv(zmq_sock, start_buf, sizeof(start_buf), 0);
    if (recv_size < 0) {
        std::cerr << "[Producer] Failed to receive START_TRANSFER: "
                  << zmq_strerror(zmq_errno()) << "\n";
        zmq_close(zmq_sock);
        zmq_ctx_destroy(zmq_ctx);
        return 1;
    }
    std::string consumerDescStr(start_buf, recv_size);
    std::cout << "[Producer] Received START_TRANSFER with Consumer descriptor list ("
              << consumerDescStr.size() << " bytes)\n";

    // 12. Deserialize Consumer's descriptor list
    nixlSerDes consumerSerdes;
    consumerSerdes.importStr(consumerDescStr);
    nixl_xfer_dlist_t consumerDescs(&consumerSerdes);
    std::cout << "[Producer] Consumer descriptor list deserialized\n";

    // 13. Create WRITE transfer request (Producer → Consumer)
    std::cout << "\n[Producer] === Initiating WRITE transfer ===\n";
    nixlXferReqH *xferReq = nullptr;
    nixl_opt_args_t xferParams;
    xferParams.backends.push_back(bknd);

    st = agent.createXferReq(NIXL_WRITE, xferDescs, consumerDescs,
                             CONSUMER_NAME, xferReq, &xferParams);
    nixl_exit_on_failure(st, "Failed to create WRITE transfer request", PRODUCER_NAME);
    std::cout << "[Producer] WRITE transfer request created\n";

    st = agent.postXferReq(xferReq, &xferParams);
    if (st != NIXL_SUCCESS && st != NIXL_IN_PROG) {
        nixl_exit_on_failure(st, "Failed to post WRITE transfer request", PRODUCER_NAME);
    }
    std::cout << "[Producer] WRITE transfer request posted\n";

    // 14. Wait for transfer completion
    std::cout << "[Producer] Waiting for WRITE transfer completion...\n";
    startTime = std::chrono::steady_clock::now();
    while (true) {
        st = agent.getXferStatus(xferReq);
        if (st == NIXL_SUCCESS) {
            std::cout << "[Producer] WRITE transfer completed!\n";
            break;
        } else if (st != NIXL_IN_PROG) {
            nixl_exit_on_failure(st, "WRITE transfer failed", PRODUCER_NAME);
        }

        auto elapsed = std::chrono::steady_clock::now() - startTime;
        if (std::chrono::duration_cast<std::chrono::seconds>(elapsed).count() > TIMEOUT_SEC) {
            std::cerr << "[Producer] Timeout waiting for WRITE transfer completion\n";
            zmq_close(zmq_sock);
            zmq_ctx_destroy(zmq_ctx);
            return 1;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    // 15. Send TRANSFER_COMPLETE via ZMQ
    const char *complete_msg = "TRANSFER_COMPLETE";
    rc = zmq_send(zmq_sock, complete_msg, strlen(complete_msg), 0);
    if (rc < 0) {
        std::cerr << "[Producer] Failed to send TRANSFER_COMPLETE: "
                  << zmq_strerror(zmq_errno()) << "\n";
        zmq_close(zmq_sock);
        zmq_ctx_destroy(zmq_ctx);
        return 1;
    }
    std::cout << "[Producer] Sent TRANSFER_COMPLETE to Consumer\n";

    zmq_close(zmq_sock);
    zmq_ctx_destroy(zmq_ctx);

    std::cout << "\n[Producer] Transfer complete!\n";
    std::cout << "[Producer] SUCCESS\n";
    return 0;
}

//=============================================================================
// CONSUMER
//=============================================================================

int runConsumer(const Config &cfg) {
    // Unbuffered I/O
    std::cout << std::unitbuf;
    std::cerr << std::unitbuf;
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    std::cout << "\n============================================\n"
              << "  Request/Response Example (vLLM-style)\n"
              << "  Mode: CONSUMER\n"
              << "  Producer IP: " << cfg.producer_ip << "\n"
              << "  Producer Port: " << cfg.port << "\n"
              << "  Descriptor exchange: TCP (port+" << 1 << ")\n"
              << "  Backend: " << cfg.backend << "\n"
              << "  Transfer: " << NUM_DESCRIPTORS << " x " << DESC_SIZE
              << " = " << TOTAL_SIZE << " bytes\n"
              << "============================================\n\n";

    nixl_status_t st;

    // 1. Initialize NIXL agent
    nixlAgentConfig agentCfg(
        true,       // use_prog_thread
        true,       // use_listen_thread
        0,          // listener port (ephemeral port for Consumer)
        nixl_thread_sync_t::NIXL_THREAD_SYNC_DEFAULT,
        1,          // num_workers
        100         // pthr_delay_us
    );
    nixlAgent agent(CONSUMER_NAME, agentCfg);
    std::cout << "[Consumer] Agent initialized\n";

    // 2. Create backend
    nixl_b_params_t backendParams;
    nixl_mem_list_t supportedMems;
    st = agent.getPluginParams(cfg.backend, supportedMems, backendParams);
    nixl_exit_on_failure(st, "Failed to get plugin params", CONSUMER_NAME);

    nixlBackendH *bknd = nullptr;
    st = agent.createBackend(cfg.backend, backendParams, bknd);
    nixl_exit_on_failure(st, "Failed to create backend", CONSUMER_NAME);
    std::cout << "[Consumer] " << cfg.backend << " backend created\n";

    nixl_opt_args_t extraParams;
    extraParams.backends.push_back(bknd);

    // 3. Allocate consumer buffer
    std::vector<uint8_t> buffer(TOTAL_SIZE);
    std::cout << "[Consumer] Buffer allocated (" << NUM_DESCRIPTORS << " descriptors)\n";

    // 4. Register memory
    nixl_reg_dlist_t regDescs(DRAM_SEG);
    for (int i = 0; i < NUM_DESCRIPTORS; i++) {
        nixlBlobDesc blobDesc;
        blobDesc.addr  = reinterpret_cast<uintptr_t>(buffer.data() + i * DESC_SIZE);
        blobDesc.len   = DESC_SIZE;
        blobDesc.devId = 0;
        regDescs.addDesc(blobDesc);
    }

    st = agent.registerMem(regDescs, &extraParams);
    nixl_exit_on_failure(st, "Failed to register memory", CONSUMER_NAME);
    std::cout << "[Consumer] Memory registered\n";

    // 5. Fetch Producer metadata (this initiates connection)
    std::cout << "[Consumer] Fetching Producer metadata...\n";
    nixl_opt_args_t mdParams;
    mdParams.ipAddr = cfg.producer_ip;
    mdParams.port = cfg.port;
    st = agent.fetchRemoteMD(PRODUCER_NAME, &mdParams);
    nixl_exit_on_failure(st, "Failed to fetch remote metadata", CONSUMER_NAME);
    std::cout << "[Consumer] Producer metadata fetched\n";

    // 6. Send Consumer metadata to Producer
    st = agent.sendLocalMD(&mdParams);
    nixl_exit_on_failure(st, "Failed to send local metadata", CONSUMER_NAME);
    std::cout << "[Consumer] Consumer metadata sent to Producer\n";

    nixl_xfer_dlist_t emptyDescs(DRAM_SEG);
    bool producerReady = false;
    auto metaStartTime = std::chrono::steady_clock::now();

    while (!producerReady) {
        producerReady = (agent.checkRemoteMD(PRODUCER_NAME, emptyDescs) == NIXL_SUCCESS);

        auto elapsed = std::chrono::steady_clock::now() - metaStartTime;
        if (std::chrono::duration_cast<std::chrono::seconds>(elapsed).count() > TIMEOUT_SEC) {
            std::cerr << "[Consumer] Timeout waiting for Producer metadata\n";
            return 1;
        }
        if (!producerReady) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    std::cout << "[Consumer] Producer metadata ready\n";

    // 7. Fetch descriptor list via TCP (ZMQ REQ)
    std::cout << "[Consumer] Fetching descriptor list from Producer...\n";
    void *zmq_ctx = zmq_ctx_new();
    void *zmq_sock = zmq_socket(zmq_ctx, ZMQ_REQ);
    std::string zmq_endpoint = "tcp://" + cfg.producer_ip + ":" + std::to_string(cfg.port + 1);
    int rc = zmq_connect(zmq_sock, zmq_endpoint.c_str());
    if (rc != 0) {
        std::cerr << "[Consumer] Failed to connect to Producer ZMQ: "
                  << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }
    std::cout << "[Consumer] Connected to " << zmq_endpoint << "\n";

    // Send request
    const char *request = "GET_DESCRIPTORS";
    rc = zmq_send(zmq_sock, request, strlen(request), 0);
    if (rc < 0) {
        std::cerr << "[Consumer] Failed to send descriptor request: "
                  << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }

    // Receive descriptor list
    char recv_buf[1024 * 1024];  // 1 MB buffer
    int recv_size = zmq_recv(zmq_sock, recv_buf, sizeof(recv_buf), 0);
    if (recv_size < 0) {
        std::cerr << "[Consumer] Failed to receive descriptor list: "
                  << zmq_strerror(zmq_errno()) << "\n";
        return 1;
    }
    std::string remoteDescStr(recv_buf, recv_size);
    std::cout << "[Consumer] Received descriptor list (" << remoteDescStr.size() << " bytes)\n";

    // 8. Serialize Consumer's descriptor list
    nixl_xfer_dlist_t localDescs = regDescs.trim();
    nixlSerDes localSerdes;
    st = localDescs.serialize(&localSerdes);
    nixl_exit_on_failure(st, "Failed to serialize local descriptor list", CONSUMER_NAME);
    std::string localDescMsg = localSerdes.exportStr();
    std::cout << "[Consumer] Local descriptor list serialized (" << localDescMsg.size() << " bytes)\n";

    // 9. Send START_TRANSFER request with Consumer's descriptor list via ZMQ
    std::cout << "\n[Consumer] === Sending START_TRANSFER request ===\n";
    rc = zmq_send(zmq_sock, localDescMsg.data(), localDescMsg.size(), 0);
    if (rc < 0) {
        std::cerr << "[Consumer] Failed to send START_TRANSFER: "
                  << zmq_strerror(zmq_errno()) << "\n";
        zmq_close(zmq_sock);
        zmq_ctx_destroy(zmq_ctx);
        return 1;
    }
    std::cout << "[Consumer] Sent START_TRANSFER request with descriptor list\n";

    // 10. Wait for TRANSFER_COMPLETE via ZMQ
    std::cout << "[Consumer] Waiting for TRANSFER_COMPLETE...\n";
    char complete_buf[32];
    recv_size = zmq_recv(zmq_sock, complete_buf, sizeof(complete_buf), 0);
    if (recv_size < 0) {
        std::cerr << "[Consumer] Failed to receive TRANSFER_COMPLETE: "
                  << zmq_strerror(zmq_errno()) << "\n";
        zmq_close(zmq_sock);
        zmq_ctx_destroy(zmq_ctx);
        return 1;
    }
    complete_buf[recv_size] = '\0';

    if (std::string(complete_buf) != "TRANSFER_COMPLETE") {
        std::cerr << "[Consumer] Expected TRANSFER_COMPLETE, got: " << complete_buf << "\n";
        zmq_close(zmq_sock);
        zmq_ctx_destroy(zmq_ctx);
        return 1;
    }
    std::cout << "[Consumer] Received TRANSFER_COMPLETE from Producer\n";

    zmq_close(zmq_sock);
    zmq_ctx_destroy(zmq_ctx);

    // 11. Verify data
    std::cout << "[Consumer] Verifying data integrity...\n";
    if (verifyConsumerData(buffer.data(), NUM_DESCRIPTORS)) {
        std::cout << "[Consumer] Data verification PASSED!\n";
    } else {
        std::cerr << "[Consumer] Data verification FAILED!\n";
        return 1;
    }

    std::cout << "\n[Consumer] SUCCESS\n";
    return 0;
}

//=============================================================================
// MAIN
//=============================================================================

int main(int argc, char *argv[]) {
    Config cfg = parseArgs(argc, argv);

    if (cfg.mode == "producer") {
        return runProducer(cfg);
    } else {
        return runConsumer(cfg);
    }
}
