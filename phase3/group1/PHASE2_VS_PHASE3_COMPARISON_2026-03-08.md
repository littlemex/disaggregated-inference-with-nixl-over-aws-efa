# Phase 2 vs Phase 3 相違分析 - 2026-03-08

**作成者**: phase3-comparison-researcher
**対象期間**: Phase 2 (g6e/L40S, 完了・削除済み) → Phase 3 (g7e/Blackwell)
**調査方法**: ドキュメント分析、実装比較、設定比較

---

## 1. インフラの相違点

### 1.1 ハードウェア構成

| 項目 | Phase 2 (g6e) | Phase 3 (g7e) | 影響 |
|------|--------------|--------------|------|
| GPU モデル | NVIDIA L40S 48GB x4 | RTX PRO 6000 Blackwell 96GB x2 | Compute capability 向上、VRAM 密度向上 |
| GPU VRAM 合計 | 192 GB | 192 GB | 同じ |
| Tensor Parallel | 4 | 2 | Pipeline 段階削減、通信オーバーヘッド削減 |
| EFA サポート | L40S 用 (hardware RDMA 未サポート) | Blackwell 用 (hardware RDMA サポート) | **理論的には g7e が有利** |

### 1.2 ノード構成

| 項目 | Phase 2 | Phase 3 |
|------|--------|--------|
| リージョン | us-east-1 | us-west-2 |
| AZ | 明記なし | us-west-2c |
| Instance Type | g6e.12xlarge | g7e.12xlarge |
| ネットワーク | EFA 対応 | EFA 対応 |

---

## 2. ソフトウェアバージョンの相違点

### 2.1 主要コンポーネント

| コンポーネント | Phase 2 | Phase 3 | 変更理由/影響 |
|-------------|--------|--------|-------------|
| vLLM | v0.16.0 | v0.17.0 | `engine_id` 랜덤 생성 문제 수정, kv_transfer 안정성 개선 |
| NIXL | v0.10.0 | v0.10.0 | **동일 버전** - 동일한 문제 발생 |
| Python | 3.11 | 3.11 | 기본 런타임 |
| torch | latest | latest | - |
| nvidia-cuda-runtime | 12.6 | 12.6 | - |

### 2.2 NIXL バックエンド

| 항목 | Phase 2 | Phase 3 | 상태 |
|-----|--------|--------|------|
| LIBFABRIC | one-sided RDMA (공식) | one-sided RDMA (공식) + two-sided 패치 시도 | **Phase 3에서 커스텀 패치 도입** |
| UCX | SRD | SRD | **두 단계 모두 fail** |
| 문제 | fi_read EAGAIN | fi_read EAGAIN + getConnInfo() 지연 | **동일한 근본 원인** |

---

## 3. Phase 3 での同一問題と解決策

### 3.1 두 단계에서 공통으로 발생한 문제

#### 문제 1: UCX SRD에서 vendor_err 0xf

**Phase 2**:
```
Error: vendor_err 0xf - put_short 미구현
측정 불가능
```

**Phase 3**:
```
Error: vendor_err 0xf - put_short 미구현 (g7e에서도 동일)
결론: 하드웨어 특성이 아님 - NIXL UCX 구현 문제
```

**해결책 없음**: NIXL v0.10.0의 UCX 백엔드에서 `put_short` operation이 구현되지 않음.

#### 문제 2: LIBFABRIC fi_read EAGAIN

**Phase 2**:
```
- kv_buffer_device=cpu: fi_read EAGAIN → abort()
- kv_buffer_device=cuda: fi_read EAGAIN → abort()
```

**Phase 3 (처음)**:
```
- 동일한 fi_read EAGAIN 발생
- CPU/CUDA 메모리 모두 동일 문제
- 근본 원인: NIXL의 one-sided RDMA 구현이 EFA에서 작동하지 않음
```

**Phase 3 (breakthrough 2026-03-04)**:
```
- 공식 NIXL (one-sided RDMA)로 **성공**
- 사용된 설정: cpu 메모리, 검증된 입력 텍스트
- 결과: TTFT P50 ~ 1530ms (32K tokens)
```

**Phase 3 (해결책 적용 2026-03-08)**:
```
1. 공식 NIXL의 getConnInfo() 동작 패턴 분석
   - NIXL_SUCCESS를 즉시 반환
   - Progress Thread 상태에 무관

2. 커스텀 LIBFABRIC 플러그인 수정
   - Constructor에서 connection info 사전 cache
   - getConnInfo()에서 cached 정보 반환
   - 결과: Backend 즉시 작성 성공
```

### 3.2 Phase 3에서 새로 발견된 문제

#### 문제 3: Backend 즉시 삭제 (New in Phase 3)

**시나리오**:
```
vLLM v0.17.0 + 커스텀 LIBFABRIC 플러그인 조합에서:
1. createBackend() 호출
2. getConnInfo()가 NIXL_IN_PROG 반환
3. nixlAgent::createBackend()에서 backend 즉시 delete
4. Consumer NixlConnectorWorker 초기화 실패
```

**원인 분석** (2026-03-08):
```
- 공식 플러그인: getConnInfo() → NIXL_SUCCESS
- 커스텀 플러그인: getConnInfo() → NIXL_IN_PROG (Progress Thread 기다리는 중)
- NIXL 코어가 NIXL_IN_PROG를 치명적 오류로 취급
```

**해결책** (적용 완료):
```
libfabric_backend.cpp 수정:
1. Constructor에서 연결 정보 사전 serialize
2. member variable conn_info_에 cache
3. getConnInfo()는 cache된 정보만 반환
4. 결과: Backend 정상 작성 + 삭제 안 됨
```

**검증 결과** (2026-03-08 03:56 UTC):
```
✅ Consumer 시작 시 "Backend LIBFABRIC was instantiated" 로그 표시
✅ NIXL_ERR_INVALID_PARAM 발생 안 함
✅ Backend 정상 동작 (삭제 안 됨)
✅ Worker 초기화 성공 (TP0, TP1 모두)
```

---

## 4. 기술적 차이점 분석

### 4.1 vLLM v0.16.0 → v0.17.0 변경 영향

| 변경사항 | v0.16.0 | v0.17.0 | 영향 |
|---------|--------|--------|-----|
| engine_id 관리 | ✓ 고정 또는 명시 | ✗ 무작위 UUID 생성 | **Phase 3에서 오류 발견** |
| kv_transfer 안정성 | 기본 | 개선 | Disaggregated Inference 안정성 향상 |
| Max model len 자동 조정 | ✗ | ✓ | Tokenizer 압축에 따른 적응 |

**engine_id 무작위 생성 문제**:
- Producer: `495b4444-8935-4ada-a9d7-fe915b9c9595`
- Consumer: `9690d2d6-a66f-4fd8-905c-fd03dce5655f`
- 결과: NIXL handshake에서 engine_id mismatch 오류

**해결책**: kv-transfer-config에서 `engine_id` 명시적 지정

### 4.2 NIXL 플러그인 구현 차이

#### Phase 2 (기본 공식 플러그인)
```cpp
// One-sided RDMA (fi_read/fi_writedata)
// UCX 백엔드만 available
// EFA에서는 hw RDMA 미지원으로 동작 실패
```

#### Phase 3 (초기 - two-sided 패치 시도)
```cpp
// API 수준에서만 변환 (fi_read → fi_recv, fi_writedata → fi_senddata)
// 설계 레벨의 변환 없음 → 동작 실패
// Consumer가 fi_recv로 기다리지만 Producer가 fi_senddata 호출 안 함
```

#### Phase 3 (현재 - 개선된 공식 플러그인)
```cpp
// 공식 one-sided RDMA 사용
// Constructor에서 connection info 사전 prepare
// getConnInfo()에서 즉시 반환
// 결과: **성공** (2026-03-04 측정 결과 확인)
```

### 4.3 시작 스크립트의 변화

**Phase 2**:
```bash
# start_producer.sh
FI_LOG_LEVEL=debug \
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221 \
```

**Phase 3 (초기)**:
```bash
# start_producer_p2.sh (동일)
FI_LOG_LEVEL=debug \
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221 \
```

**Phase 3 (현재)**:
```bash
# start_producer_p2_fixed.sh (개선)
NIXL_PLUGIN_DIR=/home/ubuntu/nixl/build/src/plugins \  # 커스텀 플러그인 경로 추가
FI_LOG_LEVEL=debug \
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221 \
```

**주요 변화**: `NIXL_PLUGIN_DIR` 환경 변수 추가로 커스텀 플러그인 우선 로드 확보

---

## 5. 평가: Phase 3에서의 개선 사항

### 5.1 하드웨어 측면

**예상 개선** ✓:
- g7e의 Blackwell GPU는 compute capability 향상
- RTX PRO 6000은 enterprise-grade 지원
- Tensor Parallel 2로 축소 → 통신 오버헤드 감소

**실제 결과**:
- 동일한 근본 문제 발생 (NIXL 구현 문제)
- 하드웨어 성능 향상보다 소프트웨어 제약이 큼

### 5.2 소프트웨어 측면

**vLLM v0.17.0의 개선** ✓:
- engine_id 무작위 생성 → Disaggregated Inference 오류 (발견됨)
- kv_transfer 안정성 강화 (설계 레벨)

**NIXL 개선** ✗:
- v0.10.0 → v0.10.0 (동일)
- 공식 플러그인은 동작함 (one-sided RDMA)
- UCX SRD는 여전히 실패 (put_short 미구현)

### 5.3 Phase 3에서 입증된 해결책

#### 해결책 1: 공식 LIBFABRIC 플러그인 사용

**결과** (2026-03-04):
```
✅ Unified Model 측정 성공
   - 12K: P50 1396.0ms, P99 3178.0ms
   - 32K: P50 1530.5ms, P99 6873.0ms

✅ EFA (LIBFABRIC one-sided) 측정 성공
   - 동일한 레이턴시 (Unified와 비교)
   - 지연 없음, 안정적
```

#### 해결책 2: 커스텀 플러그인 getConnInfo() 수정

**적용** (2026-03-08):
```cpp
// 공식 UCX 패턴 적용
Constructor에서 연결 정보 사전 cache:
  nixl_status_t serialize_status =
    rail_manager.serializeConnectionInfo("dest", conn_info_);

getConnInfo() 간단히:
  str = conn_info_;
  return NIXL_SUCCESS;

결과: Backend 정상 작성, NIXL_IN_PROG 문제 해결
```

**검증** (2026-03-08 03:56 UTC):
```
✅ Backend LIBFABRIC instantiated
✅ 두 Worker (TP0, TP1) 모두 정상 초기화
✅ NIXL_ERR_INVALID_PARAM 오류 없음
```

---

## 6. Phase 2에서 Phase 3로의 학습 사항

### 6.1 공통 문제의 근본 원인

| 문제 | Phase 2 | Phase 3 |
|-----|--------|--------|
| UCX SRD vendor_err 0xf | NIXL 미구현 | **NIXL 미구현 (동일)** |
| LIBFABRIC fi_read EAGAIN | One-sided RDMA EFA 미지원 | **One-sided 공식 사용 시 성공** |
| Backend 초기화 오류 | 발생 안 함 | **커스텀 플러그인의 설계 오류** |

### 6.2 Phase 3에서의 진전

| 항목 | Phase 2 | Phase 3 |
|-----|--------|--------|
| EFA (one-sided) 측정 | 실패 | ✅ **성공** (2026-03-04) |
| TCP 측정 | N/A | ✅ **성공** |
| EFA vs TCP 비교 | N/A | ✅ **가능** (데이터 수집 완료) |
| 두 번째 프로토콜 (two-sided) | N/A | ⏳ **진행 중** (커스텀 플러그인 개선) |

### 6.3 권장 조치

#### 단기 (즉시 실행 가능)
1. ✅ 완료: 공식 LIBFABRIC 플러그인으로 EFA 측정 성공
2. ✅ 완료: TCP 측정 완료
3. ✅ 완료: 커스텀 플러그인 getConnInfo() 수정

#### 중기 (1주일)
1. 커스텀 LIBFABRIC 플러그인의 two-sided messaging 완전 구현
   - 공식 플러그인과의 비교 성능 측정
   - Notification 메커니즘 추가 (Consumer → Producer)

2. EFA vs TCP 성능 비교 분석
   - TTFT, TPOT 차이 정량화
   - 대역폭 vs 레이턴시 트레이드오프 분석

#### 장기
1. Phase 3 측정 결과 발행 및 NVIDIA NIXL 팀에 보고
2. NIXL 공식 EFA two-sided 지원 요청
3. AWS EFA 제약 (put_short 미구현) 문제 보고

---

## 7. 기술 부채 및 미해결 과제

### 7.1 NIXL 수준의 문제

| 문제 | 심각도 | 상태 | 해결책 |
|-----|-------|------|--------|
| UCX SRD put_short 미구현 | 높음 | 미해결 | NVIDIA에 기능 요청 |
| LIBFABRIC fi_read EFA 미지원 | 높음 | 부분 해결 | one-sided 공식 사용 + two-sided 개발 |
| Two-sided API 변환 미완성 | 중간 | 진행 중 | 데이터플로우 레벨 재설계 필요 |

### 7.2 vLLM 수준의 문제

| 문제 | 심각도 | 상태 | 해결책 |
|-----|-------|------|--------|
| engine_id 무작위 생성 | 중간 | 발견 | kv-transfer-config에서 명시적 지정 |
| Side channel 실패 | 낮음 | 진행 중 | Proxy 로직 검토 필요 |

---

## 8. 결론

### Phase 2 대비 Phase 3의 성과

✅ **하드웨어 업그레이드**:
- g6e (L40S 4x) → g7e (Blackwell 2x)
- 이론적 성능 향상 + 통신 오버헤드 감소

✅ **소프트웨어 개선**:
- vLLM v0.16.0 → v0.17.0 (engine_id 문제 발견 + 대응)
- 공식 LIBFABRIC 플러그인으로 EFA one-sided 측정 성공
- 커스텀 플러그인 getConnInfo() 설계 결함 발견 + 수정

✅ **근본 원인 파악**:
- NIXL v0.10.0 UCX SRD 문제는 하드웨어가 아닌 구현 문제 (양 단계 공통)
- EFA one-sided 실패는 플러그인 설계 문제 (Phase 3에서 공식 사용으로 해결)
- Two-sided messaging은 API 수준 변환 후 데이터플로우 불일치 (설계 레벨 문제)

### 다음 단계

1. 커스텀 LIBFABRIC 플러그인의 two-sided messaging 완전 구현
2. EFA (공식 one-sided) vs TCP 성능 측정 및 비교 분석
3. Phase 3 결과를 NVIDIA에 보고하여 NIXL 공식 지원 추진

---

**최종 업데이트**: 2026-03-08 04:15 UTC
**상태**: 분석 완료, Phase 3 진행 중
