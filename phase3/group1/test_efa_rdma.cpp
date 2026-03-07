/**
 * EFA Provider RDMA Read テストプログラム
 *
 * 目的: EFA が fi_read() (one-sided RDMA Read) をサポートしているか検証
 *
 * テスト内容:
 * 1. Producer: メモリ領域を registration (FI_REMOTE_READ フラグ付き)
 * 2. Producer: memory key と address を出力
 * 3. Consumer: memory key と address を入力として受け取り
 * 4. Consumer: fi_read() で Producer のメモリから読み取り
 * 5. 結果を検証
 */

#include <rdma/fabric.h>
#include <rdma/fi_domain.h>
#include <rdma/fi_endpoint.h>
#include <rdma/fi_cm.h>
#include <rdma/fi_errno.h>
#include <rdma/fi_rma.h>

#include <iostream>
#include <cstring>
#include <string>
#include <vector>
#include <thread>
#include <chrono>

#define TEST_BUFFER_SIZE 1024
#define TEST_DATA "HELLO_FROM_PRODUCER_VIA_RDMA_READ"

class EFATestNode {
public:
    struct fid_fabric *fabric = nullptr;
    struct fid_domain *domain = nullptr;
    struct fid_ep *endpoint = nullptr;
    struct fid_cq *cq = nullptr;
    struct fid_av *av = nullptr;
    struct fi_info *info = nullptr;
    struct fi_info *hints = nullptr;

    char *buffer = nullptr;
    struct fid_mr *mr = nullptr;
    uint64_t mr_key = 0;
    void *mr_desc = nullptr;
    fi_addr_t remote_addr = FI_ADDR_UNSPEC;

    std::string role;  // "producer" or "consumer"

    ~EFATestNode() {
        cleanup();
    }

    void cleanup() {
        if (mr) fi_close(&mr->fid);
        if (buffer) free(buffer);
        if (endpoint) fi_close(&endpoint->fid);
        if (av) fi_close(&av->fid);
        if (cq) fi_close(&cq->fid);
        if (domain) fi_close(&domain->fid);
        if (fabric) fi_close(&fabric->fid);
        if (info) fi_freeinfo(info);
        if (hints) fi_freeinfo(hints);
    }

    int initialize(const std::string &node_role) {
        role = node_role;

        // Allocate hints
        hints = fi_allocinfo();
        if (!hints) {
            std::cerr << "Failed to allocate fi_info hints" << std::endl;
            return -1;
        }

        // Configure hints for RDMA Read test
        hints->caps = FI_MSG | FI_RMA | FI_READ | FI_REMOTE_READ;
        hints->ep_attr->type = FI_EP_RDM;
        hints->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_VIRT_ADDR | FI_MR_ALLOCATED | FI_MR_PROV_KEY;

        // Get fabric info for EFA provider
        int ret = fi_getinfo(FI_VERSION(1, 18), nullptr, nullptr, 0, hints, &info);
        if (ret) {
            std::cerr << "fi_getinfo failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Check if RMA is supported
        if (!(info->caps & FI_RMA)) {
            std::cerr << "ERROR: FI_RMA not supported by provider" << std::endl;
            return -1;
        }
        if (!(info->caps & FI_READ)) {
            std::cerr << "ERROR: FI_READ not supported by provider" << std::endl;
            return -1;
        }

        std::cout << "[" << role << "] Provider: " << info->fabric_attr->prov_name
                  << " (version " << info->fabric_attr->prov_version << ")" << std::endl;
        std::cout << "[" << role << "] Caps: FI_RMA=" << !!(info->caps & FI_RMA)
                  << ", FI_READ=" << !!(info->caps & FI_READ)
                  << ", FI_REMOTE_READ=" << !!(info->caps & FI_REMOTE_READ) << std::endl;

        // Open fabric
        ret = fi_fabric(info->fabric_attr, &fabric, nullptr);
        if (ret) {
            std::cerr << "fi_fabric failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Open domain
        ret = fi_domain(fabric, info, &domain, nullptr);
        if (ret) {
            std::cerr << "fi_domain failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Create completion queue
        struct fi_cq_attr cq_attr = {};
        cq_attr.format = FI_CQ_FORMAT_DATA;
        cq_attr.wait_obj = FI_WAIT_NONE;
        cq_attr.size = 128;
        ret = fi_cq_open(domain, &cq_attr, &cq, nullptr);
        if (ret) {
            std::cerr << "fi_cq_open failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Create address vector
        struct fi_av_attr av_attr = {};
        av_attr.type = FI_AV_TABLE;
        ret = fi_av_open(domain, &av_attr, &av, nullptr);
        if (ret) {
            std::cerr << "fi_av_open failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Create endpoint
        ret = fi_endpoint(domain, info, &endpoint, nullptr);
        if (ret) {
            std::cerr << "fi_endpoint failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Bind CQ and AV
        ret = fi_ep_bind(endpoint, &cq->fid, FI_SEND | FI_RECV);
        if (ret) {
            std::cerr << "fi_ep_bind (CQ) failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        ret = fi_ep_bind(endpoint, &av->fid, 0);
        if (ret) {
            std::cerr << "fi_ep_bind (AV) failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        // Enable endpoint
        ret = fi_enable(endpoint);
        if (ret) {
            std::cerr << "fi_enable failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        std::cout << "[" << role << "] Endpoint initialized successfully" << std::endl;
        return 0;
    }

    int registerBuffer(uint64_t access_flags) {
        // Allocate buffer
        buffer = (char *)aligned_alloc(4096, TEST_BUFFER_SIZE);
        if (!buffer) {
            std::cerr << "Failed to allocate buffer" << std::endl;
            return -1;
        }
        memset(buffer, 0, TEST_BUFFER_SIZE);

        if (role == "producer") {
            // Producer: write test data
            strncpy(buffer, TEST_DATA, TEST_BUFFER_SIZE);
        }

        // Register memory with specified access flags
        int ret = fi_mr_reg(domain, buffer, TEST_BUFFER_SIZE, access_flags,
                           0, 0, 0, &mr, nullptr);
        if (ret) {
            std::cerr << "fi_mr_reg failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        mr_key = fi_mr_key(mr);
        mr_desc = fi_mr_desc(mr);

        std::cout << "[" << role << "] Buffer registered:" << std::endl;
        std::cout << "  address: 0x" << std::hex << (uint64_t)buffer << std::dec << std::endl;
        std::cout << "  size: " << TEST_BUFFER_SIZE << std::endl;
        std::cout << "  mr_key: 0x" << std::hex << mr_key << std::dec << std::endl;

        return 0;
    }

    void printEndpointName() {
        char ep_name[64];
        size_t ep_name_len = sizeof(ep_name);
        int ret = fi_getname(&endpoint->fid, ep_name, &ep_name_len);
        if (ret) {
            std::cerr << "fi_getname failed: " << fi_strerror(-ret) << std::endl;
            return;
        }

        std::cout << "[" << role << "] Endpoint name (size=" << ep_name_len << "): ";
        for (size_t i = 0; i < ep_name_len && i < 64; i++) {
            printf("%02x", (unsigned char)ep_name[i]);
        }
        std::cout << std::endl;
    }

    int insertRemoteAddress(const std::vector<unsigned char> &remote_ep_name) {
        fi_addr_t addr;
        int ret = fi_av_insert(av, remote_ep_name.data(), 1, &addr, 0, nullptr);
        if (ret != 1) {
            std::cerr << "fi_av_insert failed: " << fi_strerror(-ret) << std::endl;
            return -1;
        }

        remote_addr = addr;
        std::cout << "[" << role << "] Remote address inserted: " << remote_addr << std::endl;
        return 0;
    }

    int performRdmaRead(uint64_t remote_buffer_addr, uint64_t remote_key) {
        std::cout << "[" << role << "] Performing RDMA Read..." << std::endl;
        std::cout << "  remote_addr: " << remote_addr << std::endl;
        std::cout << "  remote_buffer: 0x" << std::hex << remote_buffer_addr << std::dec << std::endl;
        std::cout << "  remote_key: 0x" << std::hex << remote_key << std::dec << std::endl;
        std::cout << "  local_buffer: 0x" << std::hex << (uint64_t)buffer << std::dec << std::endl;

        // Perform fi_read
        int ret = fi_read(endpoint, buffer, TEST_BUFFER_SIZE, mr_desc,
                         remote_addr, remote_buffer_addr, remote_key, nullptr);
        if (ret) {
            std::cerr << "fi_read failed: " << fi_strerror(-ret) << std::endl;
            return ret;
        }

        std::cout << "[" << role << "] fi_read posted successfully, waiting for completion..." << std::endl;

        // Poll for completion
        struct fi_cq_data_entry comp;
        int timeout_ms = 5000;
        auto start = std::chrono::steady_clock::now();

        while (true) {
            ret = fi_cq_read(cq, &comp, 1);
            if (ret > 0) {
                std::cout << "[" << role << "] RDMA Read completed!" << std::endl;
                break;
            } else if (ret == -FI_EAGAIN) {
                // No completion yet, check timeout
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
                if (elapsed > timeout_ms) {
                    std::cerr << "[" << role << "] TIMEOUT: No completion after " << timeout_ms << "ms" << std::endl;
                    return -1;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            } else {
                std::cerr << "[" << role << "] fi_cq_read failed: " << fi_strerror(-ret) << std::endl;
                return ret;
            }
        }

        return 0;
    }

    void printBuffer() {
        std::cout << "[" << role << "] Buffer contents: \"" << buffer << "\"" << std::endl;
    }
};

void printUsage(const char *prog) {
    std::cout << "Usage:" << std::endl;
    std::cout << "  Producer: " << prog << " producer" << std::endl;
    std::cout << "  Consumer: " << prog << " consumer <remote_ep_name_hex> <remote_buf_addr_hex> <remote_key_hex>" << std::endl;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        printUsage(argv[0]);
        return 1;
    }

    std::string role = argv[1];

    EFATestNode node;

    if (role == "producer") {
        // Producer mode
        std::cout << "=== EFA RDMA Read Test - Producer ===" << std::endl;

        if (node.initialize("producer") != 0) {
            return 1;
        }

        // Register buffer with FI_REMOTE_READ
        if (node.registerBuffer(FI_REMOTE_READ) != 0) {
            return 1;
        }

        node.printEndpointName();
        node.printBuffer();

        std::cout << "\n[Producer] Provide the following to Consumer:" << std::endl;
        std::cout << "  Endpoint name: (from above)" << std::endl;
        std::cout << "  Buffer address: 0x" << std::hex << (uint64_t)node.buffer << std::dec << std::endl;
        std::cout << "  MR key: 0x" << std::hex << node.mr_key << std::dec << std::endl;

        std::cout << "\n[Producer] Waiting for Consumer to read... (press Ctrl+C to exit)" << std::endl;
        while (true) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }

    } else if (role == "consumer") {
        // Consumer mode
        if (argc < 5) {
            printUsage(argv[0]);
            return 1;
        }

        std::cout << "=== EFA RDMA Read Test - Consumer ===" << std::endl;

        if (node.initialize("consumer") != 0) {
            return 1;
        }

        // Register local buffer with FI_READ
        if (node.registerBuffer(FI_READ) != 0) {
            return 1;
        }

        // Parse remote endpoint name (hex string)
        std::string remote_ep_hex = argv[2];
        std::vector<unsigned char> remote_ep_name;
        for (size_t i = 0; i < remote_ep_hex.length(); i += 2) {
            std::string byte_str = remote_ep_hex.substr(i, 2);
            remote_ep_name.push_back(std::stoul(byte_str, nullptr, 16));
        }

        // Insert remote address
        if (node.insertRemoteAddress(remote_ep_name) != 0) {
            return 1;
        }

        // Parse remote buffer address and key
        uint64_t remote_buf_addr = std::stoull(argv[3], nullptr, 16);
        uint64_t remote_key = std::stoull(argv[4], nullptr, 16);

        // Perform RDMA Read
        if (node.performRdmaRead(remote_buf_addr, remote_key) != 0) {
            std::cerr << "[Consumer] RDMA Read FAILED" << std::endl;
            return 1;
        }

        node.printBuffer();

        // Verify data
        if (strncmp(node.buffer, TEST_DATA, strlen(TEST_DATA)) == 0) {
            std::cout << "\n[SUCCESS] RDMA Read verified - data matches!" << std::endl;
            return 0;
        } else {
            std::cout << "\n[FAILURE] RDMA Read failed - data does not match" << std::endl;
            return 1;
        }

    } else {
        printUsage(argv[0]);
        return 1;
    }

    return 0;
}
