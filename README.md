# INT8 Matrix-Multiplication SoC Accelerator

A Verilog-based 16×16 INT8 matrix-multiplication accelerator developed using AMD Vivado. The project explores systolic-array computation, AXI interfaces, DMA-based data movement, memory architecture, and simulation-driven hardware verification.

## 1. Project Overview

The objective was to design a hardware accelerator for matrix multiplication with a dedicated parallel compute datapath, local operand buffers, and a DMA-based interface to external memory.

The design emphasizes three key aspects:

- **Parallel computation:** Exploit spatial parallelism through a systolic array of multiply-accumulate processing elements.
- **Efficient data movement:** Improve memory-transfer efficiency through a wider AXI datapath and optimized burst-based writeback.
- **Functional verification:** Validate individual modules and end-to-end operation using self-checking simulations and an independent Python/NumPy reference model.

## 2. Architecture and Design Rationale

### 2.1 Systolic Array

**Architecture:** 16×16 systolic array of processing elements.

A systolic array was chosen because matrix multiplication consists of repetitive multiply-accumulate operations that can be distributed across multiple processing elements.

Rather than executing every operation sequentially on a small number of reused arithmetic units, the array allows computation to proceed spatially in parallel as operands propagate through the datapath.

**Why this architecture?**
- Exploits parallelism inherent in matrix multiplication.
- Supports a regular, structured interconnection between processing elements.
- Provides a foundation for scaling matrix-computation throughput through hardware parallelism.

The trade-offs include increased hardware-resource requirements, interconnect complexity, operand scheduling, and control logic.

### 2.2 INT8 Multiply-Accumulate Processing Elements

The processing elements perform the multiply-accumulate operations required for matrix multiplication using INT8 operands.

INT8 arithmetic was selected to explore a compact datapath suitable for hardware acceleration. Compared with wider operand representations, narrow operands can reduce arithmetic and data-storage requirements, although actual savings depend on synthesis and implementation.

The processing elements form the computational building blocks of the systolic array, separating arithmetic functionality from higher-level control and data movement.

### 2.3 Dedicated A, B, and C Buffers

Separate buffers manage matrix A, matrix B, and output matrix C.

This organization separates operand storage and delivery from computation and result collection. It also allows the buffer modules to be verified independently.

The dedicated buffers make the data path more modular, but require additional storage and control logic to coordinate loading, computation, and writeback.

### 2.4 AXI4-Lite Control Interface

An AXI4-Lite register block provides the software-visible control and configuration interface.

Separating control-register transactions from bulk matrix transfers gives the accelerator a clear programming interface while keeping high-volume data movement in a dedicated DMA path.

### 2.5 AXI DMA and External Memory

A dedicated DMA module handles transfers between external memory and the accelerator.

DMA was chosen to separate bulk data movement from computation and control-register accesses. The design uses a 64-bit AXI data interface, allowing eight bytes to be transferred per data beat.

The DMA and memory model must consistently handle burst lengths, addresses, data beats, and transaction responses. Consequently, DMA verification is an important part of the project rather than simply an implementation detail.

## 3. Architectural Improvements and Optimizations

### 3.1 Widening the AXI Datapath: 32-bit to 64-bit

The original DMA configuration used a 32-bit data interface. The datapath was widened to 64 bits, doubling the amount of data transferred per AXI beat from four bytes to eight bytes.

For the same amount of transferred data, this reduces the number of required data beats by approximately half, assuming equivalent transfer organization. It can improve effective bandwidth and reduce transfer overhead.

| Property | 32-bit DMA | 64-bit DMA |
|---|---:|---:|
| AXI data width | 32 bits | 64 bits |
| Bytes per beat | 4 | 8 |
| LOAD_A average | 94.06 cycles | 48.76 cycles |
| LOAD_B average | 91.33 cycles | 47.00 cycles |
| STORE_C average | 361.94 cycles | 184.94 cycles |

In the reported DMA simulations, the 64-bit configuration reduced average transfer-phase cycle counts by approximately 48–49%, corresponding to approximately **1.93–1.96× the transfer-phase performance** in these measurements.

This is the more substantial of the two measured optimizations.

The trade-offs include a wider datapath and associated interface logic, along with the need to update and verify compatible DMA and memory-model behavior.

These are DMA benchmark results, not evidence of a 1.9× improvement in total accelerator execution time. Overall latency also includes computation, control overhead, and memory stalls.

### 3.2 Optimizing C-Matrix Writeback Burst Length

The C-matrix writeback was subsequently optimized by changing the write-burst length from 16 beats to 32 beats.

The original implementation transferred 128 beats using eight bursts of 16 beats. The optimized implementation transfers the same 128 beats using four bursts of 32 beats.

| Property | Original | Optimized |
|---|---:|---:|
| Total C write data | 128 beats | 128 beats |
| Beats per burst | 16 | 32 |
| Number of write bursts | 8 | 4 |
| Write-address transactions | 8 | 4 |

The optimization halves the number of write bursts and address transactions without changing the total amount of output data transferred. It requires the DMA, memory model, and testbench to support the revised write-burst length.

The A and B read paths continue to use 16-beat bursts.

### 3.3 End-to-End Simulation Comparison

The following results were reported before and after the C writeback burst-length optimization.

| Metric | Original | Optimized |
|---|---:|---:|
| Average end-to-end cycles | 356.27 | 352.67 |
| Average STORE_C phase | 172.47 | 168.47 |
| Derived latency at 100 MHz | 3.5627 µs | 3.5267 µs |

The observed end-to-end cycle count decreased by approximately **1.01%**, while the average STORE_C phase decreased by approximately **2.32%**.

The improvement is modest. Randomized memory stalls can affect these measurements, so the comparison is not a fully controlled benchmark and the reduction cannot be attributed exclusively to burst length without further experiments.

The 32-bit-to-64-bit comparison and the burst-length comparison are distinct experiments and should not be combined into a single speedup figure.

## 4. Verification Methodology

The project uses module-level tests and end-to-end simulations driven by Python.

### Module-Level Verification

The test suite covers:

- Multiply-accumulate processing elements.
- Systolic-array functionality.
- Operand and output buffers.
- Core and control logic.
- AXI4-Lite register behavior.
- DMA transfer and burst handling.
- Top-level accelerator operation.

### End-to-End Verification

The end-to-end testbench connects the accelerator to a simulated external-memory model and exercises the complete data path.

A Python/NumPy reference model independently calculates expected matrix results. The simulated DRAM contents are then checked against the reference model.

The memory model also introduces randomized behavior to exercise transaction handling under non-ideal conditions.

### Reported Verification Results

- All project tests pass in the current working setup.
- 21 end-to-end test jobs are exercised, including six expected-error cases.
- 15 jobs complete successfully.
- 4,096 DRAM words are checked against the Python reference model.
- Successful C writebacks use four 32-beat bursts, transferring 128 beats.

The six expected-error cases exercise error handling and are not counted as successful computation jobs.

## 5. Performance Summary

The following figures are from the reported optimized end-to-end simulation.

| Metric | Result |
|---|---:|
| Average cycles per successful job | 352.67 |
| Assumed clock frequency | 100 MHz |
| Derived average latency | 3.5267 µs |
| C-matrix write data | 128 beats |
| C-matrix write bursts | 4 |
| Beats per C write burst | 32 |

The latency is derived from simulated cycle counts using an assumed 100 MHz clock. It is not a measured execution time on a physical FPGA.

The results demonstrate functional correctness in simulation and a modest reduction in observed end-to-end cycle count after the writeback optimization.

The larger improvement from widening the DMA datapath applies to the reported transfer phases and should not be presented as the overall accelerator speedup.

## FPGA Synthesis and Timing Results

The accelerator was implemented for the xc7z020clg484-1 FPGA board configured in the Vivado project. The reported implementation results show that the design meets the specified timing constraints, with no failing setup or hold endpoints.

### Resource Utilization

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| LUTs | 10,353 | 53,200 | 19.46% |
| Flip-flops | 9,095 | 106,400 | 8.55% |
| DSPs | 192 | 220 | 87.27% |

The implementation uses less than one-fifth of the available LUTs and under one-tenth of the available flip-flops, while consuming 87.27% of the available DSP resources.

DSPs are the most constrained resource in this implementation. This is an important architectural consideration when evaluating further parallelism or scaling the accelerator.

### Timing Summary

| Timing metric | Result |
|---|---:|
| Worst Negative Slack (WNS) | +2.499 ns |
| Total Negative Slack (TNS) | 0.000 ns |
| Worst Hold Slack (WHS) | +0.236 ns |
| Total Hold Slack (THS) | 0.000 ns |
| Failing setup endpoints | 0 |
| Failing hold endpoints | 0 |

Vivado reports that all user-specified timing constraints are met. The positive setup and hold slack and zero failing endpoints indicate that the implementation satisfies the reported timing checks.

The reported WNS is relative to the timing constraints supplied to Vivado. It should not be interpreted as the maximum achievable operating frequency without the corresponding clock constraints and timing reports.

### Implementation Trade-offs

The resource distribution highlights the trade-off between parallel arithmetic and FPGA resource consumption. The design uses 192 DSPs, making DSP utilization the primary resource constraint among the reported metrics.

Future optimization could explore arithmetic resource sharing, alternative processing-element implementations, and different degrees of parallelism. Any such changes should be evaluated against both timing closure and end-to-end performance.

These resource and timing figures describe the reported FPGA implementation; the separate latency and DMA comparisons elsewhere in this README are simulation measurements.


## 6. Tools and Technologies

- Verilog HDL
- AMD Vivado
- AXI and AXI4-Lite interfaces
- DMA and burst-based memory transfers
- Python
- NumPy
- Self-checking Verilog testbenches
- Randomized memory simulation
- Reference-model verification

## 7. Repository Structure

The repository preserves the existing Vivado project structure to avoid breaking project paths and simulation scripts.

- `project_1/` — Vivado project and associated source files.
- `project_1/project_1.srcs/sources_1/new/` — RTL modules.
- `project_1/project_1.srcs/sim_1/new/` — simulation testbenches and memory model.
- `project_1/python/` — Python-driven simulation and performance-test infrastructure.
- `test_*.py` — module-level and integration test scripts.
- `test_all.py` — aggregate test runner.
- `.gitignore` — excludes generated files and local development artifacts.

Generated simulation outputs, temporary Vivado files, and local Python environments are excluded from version control.

## 8. Limitations and Future Work

The current results establish functional correctness in simulation and demonstrate improvements in DMA transfer behavior.

Potential next steps include:

- Running controlled benchmarks with fixed memory-stall patterns to isolate the effects of burst length and datapath width.
- Synthesizing the RTL and analyzing LUT, flip-flop, DSP, and memory utilization.
- Performing implementation and timing analysis to establish achievable clock frequency.
- Measuring end-to-end throughput and latency on physical FPGA hardware.
- Investigating additional bottlenecks in operand loading, computation scheduling, and result writeback.
- Evaluating resource, timing, and power trade-offs for alternative datapath configurations.
