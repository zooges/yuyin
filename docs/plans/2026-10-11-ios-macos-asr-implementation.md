# Yuyin iOS/macOS ASR Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a working SwiftUI iOS+macOS client with 2-pass Chinese ASR, user-selectable Offline/Hybrid/Cloud modes, export, and model/cloud provider plumbing.

**Architecture:** YuyinCore orchestrates Capture → StreamingASR → VAD endpoint → CorrectorASR → SessionStore. YuyinLocal wraps sherpa-onnx (with Apple Speech fallback). YuyinCloud hosts FunASR/Doubao providers. Single Xcode multiplatform app.

**Tech Stack:** Swift 5.10, SwiftUI, AVAudioEngine, GRDB optional (start with in-memory+JSON persist), sherpa-onnx-spm when linkable, SFSpeechRecognizer fallback, URLSession WebSocket.

---

### Task 1: Repo skeleton + packages

Create Package.swift workspace layout, .gitignore, README, Models download script stub.

### Task 2: YuyinCore models + session + orchestrator

Utterance, TranscriptMode, ASR protocols, TwoPassOrchestrator, SessionStore, Export.

### Task 3: YuyinLocal — Apple Speech streaming + offline correction shim

Working without large model download; sherpa adapter behind protocol when models exist.

### Task 4: YuyinCloud — FunASR realtime stub + protocol

Configurable base URL/API key; mock provider for tests.

### Task 5: SwiftUI app (macOS+iOS)

Record UI, live transcript, mode picker, settings, export.

### Task 6: Xcode project via XcodeGen + build verify

### Task 7: Unit tests for state machine + mode fallback

### Task 8: Wire M2/M3 features — model download UI, persistence, polish

---
