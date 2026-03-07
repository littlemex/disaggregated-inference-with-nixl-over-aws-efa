# EFA RDMA Read テストプログラム Makefile

CXX = g++
CXXFLAGS = -std=c++11 -Wall -O2 -I/opt/amazon/efa/include
LDFLAGS = -L/opt/amazon/efa/lib -lfabric -lpthread

TARGET = test_efa_rdma

all: $(TARGET)

$(TARGET): test_efa_rdma.cpp
	$(CXX) $(CXXFLAGS) -o $(TARGET) test_efa_rdma.cpp $(LDFLAGS)

clean:
	rm -f $(TARGET)

test-producer:
	./$(TARGET) producer

test-consumer:
	@echo "Usage: make test-consumer REMOTE_EP=<hex> REMOTE_BUF=<hex> REMOTE_KEY=<hex>"
	@echo "Example: make test-consumer REMOTE_EP=fe80... REMOTE_BUF=0x7f1234567890 REMOTE_KEY=0x1"

.PHONY: all clean test-producer test-consumer
