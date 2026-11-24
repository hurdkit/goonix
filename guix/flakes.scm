;;; goonix: the declarations and locks of flakes, in one module.
;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2026 goonix contributors
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

(define-module (guix flakes)
  #:use-module (guix flakes syntax)
  #:use-module (guix flakes lock)
  #:use-module (guix flakes resolve)
  #:re-export (flake? flake-format flake-description flake-modules
               flake-inputs flake-options flake-outputs-expression
               flake-input? flake-input-name flake-input-type flake-input-url
               flake-input-path flake-input-branch flake-input-tag
               flake-input-commit flake-input-as flake-input-worktree?
               flake-input-pinned? flake-input-follows flake-input-overrides
               flake-input-options flake-input-introduction
               flake-option? flake-option-name flake-option-type
               flake-option-default flake-option-description
               read-flake

               flake-lock? flake-lock-inputs flake-lock-nodes
               lock-node? lock-node-id lock-node-type lock-node-url
               lock-node-path lock-node-branch lock-node-tag
               lock-node-commit lock-node-tree-hash lock-node-worktree?
               lock-node-authentication lock-node-inputs
               lock-edge? lock-edge-name lock-edge-node lock-edge-kind
               lock-edge-as lock-edge-options lock-edge-target
               flake-lock-node flake-lock-root-edge lock-node-edge
               read-flake-lock write-flake-lock flake-lock->string

               resolve-flake-lock lock-flake effective-flake-lock
               read-local-overrides parse-input-override
               lock-node-tree lock-notices flake-metadata))
