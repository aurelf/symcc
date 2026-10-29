; This file is part of SymCC.
;
; SymCC is free software: you can redistribute it and/or modify it under the
; terms of the GNU General Public License as published by the Free Software
; Foundation, either version 3 of the License, or (at your option) any later
; version.
;
; SymCC is distributed in the hope that it will be useful, but WITHOUT ANY
; WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
; A PARTICULAR PURPOSE. See the GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License along with
; SymCC. If not, see <https://www.gnu.org/licenses/>.

; Verify that symbolic vector values use the same lane and byte order no matter
; whether they come from memory or are built by vector instructions. Loads and
; stores treat a vector like an integer of the same width (on little-endian
; targets, lane 0 is in the least significant bits), so extracting, inserting
; and computing on lanes must agree with that layout. Otherwise the solver
; reasons about the wrong lane, or about byte-swapped lane values, and generates
; inputs that don't take the branch.
;
; The 16-byte input is a <4 x i32>. Each scenario uses a distinct lane, so each
; expected solution is unique:
;   1. vector load, extractelement of lane 1 == 0x11223344
;        -> bytes 4..7 = 44 33 22 11
;   2. vector load, add 1 to every lane (carry crosses a byte), vector store,
;      scalar load of lane 2 == 0x100
;        -> bytes 8..11 = ff 00 00 00
;   3. scalar load of lane 3, insertelement into lane 3, vector store, scalar
;      load of lane 3 == 0x55667788
;        -> bytes 12..15 = 88 77 66 55
;
; The simple backend prints its solutions, so we check them directly. The QSYM
; backend reports them through the test-case handler, which prints "sN solved"
; only if the generated input really satisfies the condition of scenario N.
;
; Since the bitcode is written by hand, we first run llc on it because it
; performs a validity check, whereas Clang doesn't.

; RUN: llc %s -o /dev/null
; RUN: %symcc %s -o %t
; RUN: env SYMCC_MEMORY_INPUT=1 %t 2>&1 | %filecheck %s

target triple = "x86_64-pc-linux-gnu"

@s1_hit = private constant [7 x i8] c"s1 hit\0A"
@s2_hit = private constant [7 x i8] c"s2 hit\0A"
@s3_hit = private constant [7 x i8] c"s3 hit\0A"
@s1_end = private constant [7 x i8] c"s1 end\0A"
@s2_end = private constant [7 x i8] c"s2 end\0A"
@s3_end = private constant [7 x i8] c"s3 end\0A"
@s1_solved = private constant [10 x i8] c"s1 solved\0A"
@s2_solved = private constant [10 x i8] c"s2 solved\0A"
@s3_solved = private constant [10 x i8] c"s3 solved\0A"

define i32 @main(i32 %argc, ptr %argv) {
entry:
  call void @symcc_set_test_case_handler(ptr @handle_test_case)
  %in = alloca <4 x i32>, align 16
  %out = alloca <4 x i32>, align 16
  store <4 x i32> zeroinitializer, ptr %in, align 16
  call void @symcc_make_symbolic(ptr %in, i64 16)

  ; Scenario 1: extract a lane from a vector loaded from memory.
  %v = load <4 x i32>, ptr %in, align 16
  %lane1 = extractelement <4 x i32> %v, i32 1
  %c1 = icmp eq i32 %lane1, 287454020
  ; SIMPLE: Trying to solve
  ; SIMPLE: Found diverging input
  ; SIMPLE-DAG: stdin4 -> #x44
  ; SIMPLE-DAG: stdin5 -> #x33
  ; SIMPLE-DAG: stdin6 -> #x22
  ; SIMPLE-DAG: stdin7 -> #x11
  ; QSYM: s1 solved
  br i1 %c1, label %s1_hit, label %s1_end

s1_hit:
  call i64 @write(i32 2, ptr @s1_hit, i64 7)
  br label %s1_end

s1_end:
  call i64 @write(i32 2, ptr @s1_end, i64 7)
  ; ANY: s1 end

  ; Scenario 2: lane-wise arithmetic with a carry across bytes, stored back to
  ; memory and read as a scalar.
  %sum = add <4 x i32> %v, <i32 1, i32 1, i32 1, i32 1>
  store <4 x i32> %sum, ptr %out, align 16
  %p2 = getelementptr i32, ptr %out, i64 2
  %lane2 = load i32, ptr %p2, align 8
  %c2 = icmp eq i32 %lane2, 256
  ; SIMPLE: Trying to solve
  ; SIMPLE: Found diverging input
  ; SIMPLE-DAG: stdin8 -> #xff
  ; SIMPLE-DAG: stdin9 -> #x00
  ; SIMPLE-DAG: stdin10 -> #x00
  ; SIMPLE-DAG: stdin11 -> #x00
  ; QSYM: s2 solved
  br i1 %c2, label %s2_hit, label %s2_end

s2_hit:
  call i64 @write(i32 2, ptr @s2_hit, i64 7)
  br label %s2_end

s2_end:
  call i64 @write(i32 2, ptr @s2_end, i64 7)
  ; ANY: s2 end

  ; Scenario 3: insert a symbolic scalar into a concrete vector, store the
  ; vector and read the lane back as a scalar.
  %p3in = getelementptr i32, ptr %in, i64 3
  %x3 = load i32, ptr %p3in, align 4
  %ins = insertelement <4 x i32> zeroinitializer, i32 %x3, i32 3
  store <4 x i32> %ins, ptr %out, align 16
  %p3 = getelementptr i32, ptr %out, i64 3
  %lane3 = load i32, ptr %p3, align 4
  %c3 = icmp eq i32 %lane3, 1432778632
  ; SIMPLE: Trying to solve
  ; SIMPLE: Found diverging input
  ; SIMPLE-DAG: stdin12 -> #x88
  ; SIMPLE-DAG: stdin13 -> #x77
  ; SIMPLE-DAG: stdin14 -> #x66
  ; SIMPLE-DAG: stdin15 -> #x55
  ; QSYM: s3 solved
  br i1 %c3, label %s3_hit, label %s3_end

s3_hit:
  call i64 @write(i32 2, ptr @s3_hit, i64 7)
  br label %s3_end

s3_end:
  call i64 @write(i32 2, ptr @s3_end, i64 7)
  ; ANY: s3 end
  ret i32 0
}

; Print "sN solved" for each scenario whose condition the generated input
; satisfies (QSYM backend only; the simple backend doesn't call handlers).
define void @handle_test_case(ptr %data, i64 %len) {
entry:
  %long_enough = icmp uge i64 %len, 16
  br i1 %long_enough, label %check1, label %done

check1:
  %q1 = getelementptr i8, ptr %data, i64 4
  %d1 = load i32, ptr %q1, align 1
  %k1 = icmp eq i32 %d1, 287454020
  br i1 %k1, label %ok1, label %check2

ok1:
  call i64 @write(i32 2, ptr @s1_solved, i64 10)
  br label %check2

check2:
  %q2 = getelementptr i8, ptr %data, i64 8
  %d2 = load i32, ptr %q2, align 1
  %k2 = icmp eq i32 %d2, 255
  br i1 %k2, label %ok2, label %check3

ok2:
  call i64 @write(i32 2, ptr @s2_solved, i64 10)
  br label %check3

check3:
  %q3 = getelementptr i8, ptr %data, i64 12
  %d3 = load i32, ptr %q3, align 1
  %k3 = icmp eq i32 %d3, 1432778632
  br i1 %k3, label %ok3, label %done

ok3:
  call i64 @write(i32 2, ptr @s3_solved, i64 10)
  br label %done

done:
  ret void
}

declare void @symcc_make_symbolic(ptr, i64)
declare void @symcc_set_test_case_handler(ptr)
declare i64 @write(i32, ptr, i64)
