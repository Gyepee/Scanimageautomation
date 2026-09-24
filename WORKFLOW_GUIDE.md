# ScanImage 수집·복사·업로드 운영 가이드

이 문서는 `F:\Data\jisooj`에 생성되는 ScanImage 세션이 왜 현재 구조로
정리되는지 설명하는 기준 문서다. 코드와 문서가 다르면 코드를 임의로
추측하지 말고 버전과 로그를 먼저 확인한다.

## 현재 권장 버전 조합

| 구성요소 | 권장 버전 | 역할 |
|---|---:|---|
| Pre-GRAB Guard | 2.2.0 | 저장 경로·채널·WaveSurfer·PortBlank 설정 확인 |
| LocalConsolidate | 3.3.0 | 세션 파일 고정, 세 선택지 처리, manifest/job 생성 |
| CopyWorker | 2.1.0 | TIFF/H5 시간 기준으로 Bonsai·Bpod 복사 |
| Verifier | 2.1.0 | 세션 파일과 시간·짝·동물 ID 재검증 |
| UploadWorker | 2.1.0 | manifest와 copy status를 통과한 세션만 업로드 |
| Manifest schema | 2.0 | 수집 목적과 실제 파일 inventory 기록 |

`schema_version`은 데이터 명세 형식의 버전이고, `producer.version`은 그
manifest를 만든 LocalConsolidate 로직 버전이다. CopyWorker와 Verifier
버전은 `external_copy_status.json`에, UploadWorker 버전은 업로드 완료 상태
파일에 기록된다.

## 설계 원칙

1. 파일 소속은 consolidation 버튼을 누른 시각으로 판단하지 않는다.
2. `acqAbort` callback에서 이번 세션의 정확한 TIFF/H5 경로를 고정한다.
3. 외부 파일 매칭 기준은 고정된 TIFF의 생성시각과 TIFF/H5의 최종
   쓰기시각이다.
4. 다음 GRAB과 consolidation이 겹쳐도 GRAB을 차단하지 않는다.
5. Pre-GRAB Guard는 TIFF/H5를 이동하거나 정리하지 않는다.
6. 정상 종료와 QC는 항상 세션 폴더와 manifest를 만든다.
7. Cancel은 업로드 가능한 세션을 만들지 않는다.
8. 어느 세션에도 안전하게 귀속할 수 없는 파일은 자동 병합하지 않는다.

## 전체 흐름

```text
GRAB 종료(acqAbort)
  -> 이번 TIFF/H5 경로 고정
  -> H5 쓰기 안정화 확인
  -> 사용자 선택: 정상 종료 / QC / Cancel

정상 종료 또는 QC
  -> 고정 TIFF/H5를 세션 폴더로 이동
  -> manifest v2 작성(awaiting_external_copy)
  -> CopyWorker job 생성
  -> TIFF/H5 시간에 맞는 Bonsai/Bpod 복사
  -> manifest 파일 목록 갱신 및 finalized
  -> Verifier/UploadWorker 검사
  -> 원격 업로드

Cancel
  -> 이번 TIFF/H5만 날짜별 _cancelled_sessions로 이동
  -> manifest/job/upload 없음
```

## 팝업의 세 선택지

| 선택 | 결과 | 업로드 대상 |
|---|---|---|
| Bonsai Stopped, Consolidate | 정상 세션 폴더와 표준 manifest 생성 | 예 |
| QC Consolidate | 정상 세션 폴더와 QC manifest 생성 | 예 |
| Cancel | 이번 TIFF/H5를 `_cancelled_sessions`로 이동 | 아니오 |

### 정상 종료

표준 세션은 CopyWorker가 Bpod protocol과 laser 설정을 이용해 최종 목적을
결정한다.

- `behavior_training`: Bpod `Training` protocol을 수행한 훈련 세션
- `behavior_only_experiment`: `GoalExperiment`를 수행했지만 imaging laser는 사용하지 않은 행동 전용 실험
- `openfield_experiment`: laser power가 있고 정상 Bpod/영상 파일이 있는 실험

표준 세션은 원칙적으로 다음 파일을 가진다.

- ScanImage TIFF
- WaveSurfer H5
- Bonsai MP4
- Bonsai timestamp CSV
- Bpod MAT
- Bpod SessionSummary TXT/CSV
- Bpod protocol backup M(존재하는 경우)
- `collection_manifest.json`
- `external_copy_status.json`

### QC

QC 버튼을 눌러도 별도 `QC` 데이터 루트를 사용하지 않는다. 모든 mini2p
세션은 `F:\Data\jisooj` 아래 같은 폴더 규칙을 사용하고 manifest purpose로
구분한다.

- MP4/CSV가 있는 QC
  - `collection_purpose`: `openfield_fov_qc`
  - `behavior_protocol`: `openfield_free`
  - `utlens_z` 기록
- MP4/CSV가 없는 QC
  - `collection_purpose`: `headfixed_fov_qc`
  - `behavior_protocol`: `none`
  - `motor_position` 기록

QC에서 Bpod 파일은 요구하지 않는다. MP4와 timestamp CSV는 반드시 완전한
쌍이어야 한다.

### Cancel

Cancel은 비정상 종료 세션을 만들지 않기 위한 선택이다. 이번 세션의 고정된
TIFF/H5만 다음 경로로 이동한다.

```text
F:\Data\jisooj\_cancelled_sessions\YYYY-MM-DD\
  cancelled_HHMMSS_mmm_scan<SCAN_ID>\
```

Cancel 폴더에는 manifest와 CopyWorker job을 만들지 않으며 업로드 검색
대상이 아니다.

## 귀속 불명 파일

정상/QC consolidation 또는 Cancel 시점에 이번 세션의 고정 TIFF/H5가 아닌
이전 잔류 파일이 발견되면 다음 위치로 분리한다.

```text
F:\Data\jisooj\_unresolved_sessions\YYYY-MM-DD\
  unresolved_HHMMSS_mmm_before_scan<SCAN_ID>\
```

이 파일은 삭제하거나 다른 세션에 자동 병합하지 않는다. 생성·최종 쓰기시각,
ScanImage/Bonsai/Bpod 로그를 확인한 뒤 수동 복구한다. 과거
`_archived_by_preflight`는 이전 로직의 보존 기록이며 새 코드에서는 쓰지 않는다.

## 세션 폴더 및 파일명

세션 폴더:

```text
<STEM>_YYYY-MM-DD_scan<SCAN_ID>_sess<SESSION_ID>
```

예:

```text
JJ_ROS-2335_2026-09-24_scan9G2DIJ81_sess9G2DIJ81
```

로컬 파일은 원래 이름 앞에 scan ID를 붙인다.

```text
scan9G2DIJ81_JJ_ROS-2335_02031.tif
scan9G2DIJ81_JJ_ROS-2335_2031.h5
```

CopyWorker가 복사하는 외부 파일도 같은 접두사를 사용한다.

```text
scan9G2DIJ81_mini2p2_top_video_2026-09-24T14_51_36.mp4
scan9G2DIJ81_mini2p2_top_video_timestamps_tracking_2026-09-24T14_51_36.csv
scan9G2DIJ81_ROS-2335_GoalExperiment_20260924_145016.mat
scan9G2DIJ81_ROS-2335_GoalExperiment_20260924_145016_SessionSummary.txt
scan9G2DIJ81_ROS-2335_GoalExperiment_20260924_145016_SessionSummary.csv
```

## CopyWorker 시간 매칭

CopyWorker는 job 생성시각이나 팝업 확인시각을 사용하지 않는다.

- 이미징 시작: 세션 폴더의 최신 TIFF `CreationTime`
- 이미징 종료: 세션 폴더 TIFF/H5 중 가장 늦은 `LastWriteTime`
- Bonsai:
  - 0바이트 파일 제외
  - 같은 timestamp token의 MP4/CSV 쌍만 허용
  - 이미징 종료시각과 가장 가까운 완성된 쌍 선택
- Bpod:
  - 동물 ID가 일치하는 개별 MAT 후보를 검사
  - 파일명의 Bpod 시작시각이 이미징 구간과 맞아야 함
  - MAT 완료시각이 이미징 구간과 겹쳐야 함
  - 네트워크 폴더의 단순 최신 파일은 사용하지 않음

TIFF/H5 시간 anchor가 없으면 외부 파일을 추측해서 복사하지 않고 실패로
기록한다.

## Manifest v2

모든 새 업로드 세션은 `collection_manifest.json`을 가져야 한다. 핵심 필드는:

- `schema_name`: `scanimage_collection_manifest`
- `schema_version`: `2.0`
- `producer.name`, `producer.version`
- `collection_status`: CopyWorker 전에는 `awaiting_external_copy`, 완료 후 `finalized`
- `setup_type`
- `animal_id`
- `scan_id`
- `behavior_protocol`
- `session_timestamp`: callback 기록용 시각이며 외부 파일 매칭 기준은 아님
- `collection_purpose`
- `utlens_z` 또는 `motor_position`(해당되는 경우)
- `laser_power`
- `collected_files`: 파일명과 byte 크기의 최종 inventory

`pending_*`, `needs_manual_classification`, 빈 purpose는 최종 업로드 가능한
분류가 아니다.

## 업로드 조건

UploadWorker 2.1.0부터 정상 세션과 QC 모두 manifest 기반으로 검사한다.

공통 조건:

- manifest schema 2.0
- `collection_status=finalized`
- `finalized_at` 존재
- manifest inventory와 실제 파일명/크기가 정확히 일치
- `external_copy_status.json`이 `DONE`
- `fail_count=0`
- 0바이트 주요 데이터 파일 없음
- 폴더명, TIFF/H5, Bpod, manifest의 동물 ID 일치
- 설정된 안정화 시간 경과

표준 세션의 허용 purpose:

- `behavior_training`
- `behavior_only_experiment`
- `openfield_experiment`

QC의 허용 purpose:

- `headfixed_fov_qc`
- `openfield_fov_qc`
- `bench2p_zstack`
- `bench2p_fov_qc`

`_cancelled_sessions`, `_unresolved_sessions`, `_archived_by_preflight`는 세션
폴더 이름 규칙(`_scan..._sess...`)과 맞지 않으므로 업로드 대상이 아니다.

## 설치와 버전 확인

ScanImage가 idle일 때 Pre-GRAB listener를 갱신한다.

```matlab
userfcn_RemovePreGrabGuard
userfcn_InstallPreGrabGuard
```

정상 로그:

```text
Installed Pre-GRAB Guard v2.2.0 listener on hSI.acqState.
=== Starting Local Consolidation v3.3.0 for the Session ===
```

CopyWorker와 UploadWorker는 디스크의 PowerShell 스크립트를 매번 새로 실행하므로
별도 설치가 필요 없다.

## 점검 명령

한 세션을 읽기 전용으로 검증:

```powershell
.\scripts\upload\verify_session_folder_for_upload.ps1 `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER"
```

검증 결과를 상태 JSON에 반영:

```powershell
.\scripts\upload\verify_session_folder_for_upload.ps1 `
  -SessionPath "F:\Data\jisooj\SESSION_FOLDER" `
  -UpdateStatus
```

업로드 대상 사전 확인:

```powershell
.\scripts\upload\upload_completed_sessions_from_config.ps1 -DryRun
```

## 변경 관리

- 시간 기준이나 파일명 규칙을 바꾸면 LocalConsolidate, CopyWorker, Verifier,
  UploadWorker와 이 문서를 함께 검토한다.
- manifest 필드를 호환 불가능하게 바꾸면 `schema_version`을 올린다.
- 동작만 바꾸고 schema가 호환되면 해당 component version만 올린다.
- 운영 적용 전 MATLAB/PowerShell 구문검사, dry-run, 보안 무결성 검사를 수행한다.
- 검증된 권장 버전 조합을 변경한 뒤에는 이 문서의 표를 먼저 갱신한다.
