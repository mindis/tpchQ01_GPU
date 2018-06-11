#include "data_types.h"
#include "constants.hpp"
#include "bit_operations.h"
#include "kernel.hpp"
#include "kernels/ht_in_global_mem.hpp"
#include "kernels/ht_in_registers.cuh"
#include "kernels/ht_in_local_mem.cuh"
#include "kernels/ht_per_thread_in_shared_mem.cuh"
// #include "kernels/ht_per_block_in_shared_mem.cuh"
#include "../expl_comp_strat/tpch_kit.hpp"
#include "../expl_comp_strat/common.hpp"
#include "cpu/common.hpp"
#include "cpu.h"

#include <iostream>
#include <cuda/api_wrappers.h>
#include <vector>
#include <iomanip>
#include <fstream>
#include <chrono>
#include <tuple>
#include <unordered_map>

#ifndef GPU
#error The GPU preprocessor directive must be defined (ask Tim for the reason)
#endif

using std::tie;
using std::make_pair;
using std::make_unique;
using std::unique_ptr;
using std::cout;
using std::cerr;
using std::endl;
using std::flush;
using std::string;

size_t magic_hash(char rf, char ls) {
    return (((rf - 'A')) - (ls - 'F'));
}

inline void assert_always(bool a) {
    assert(a);
    if (!a) {
        fprintf(stderr, "Assert always failed!");
        exit(1);
    }
}

void syscall(string command) {
    auto x = system(command.c_str());
    (void) x;
}

#define GIGA (1024 * 1024 * 1024)
#define MEGA (1024 * 1024)
#define KILO (1024)

using timer = std::chrono::high_resolution_clock;

inline bool file_exists(const string& name) {
    struct stat buffer;
    return (stat (name.c_str(), &buffer) == 0);
}

inline string join_path(string a, string b) {
    return a + "/" + b;
}

std::ifstream::pos_type filesize(string filename) {
    std::ifstream in(filename.c_str(), std::ifstream::ate | std::ifstream::binary);
    return in.tellg();
}

template <bool Compressed>
struct stream_input_buffer_set;

enum : bool { is_compressed = true, is_not_compressed = false};

template <> struct stream_input_buffer_set<is_compressed> {
    cuda::memory::device::unique_ptr< compressed::ship_date_t[]      > ship_date;
    cuda::memory::device::unique_ptr< compressed::discount_t[]       > discount;
    cuda::memory::device::unique_ptr< compressed::extended_price_t[] > extended_price;
    cuda::memory::device::unique_ptr< compressed::tax_t[]            > tax;
    cuda::memory::device::unique_ptr< compressed::quantity_t[]       > quantity;
    cuda::memory::device::unique_ptr< bit_container_t[]              > return_flag;
    cuda::memory::device::unique_ptr< bit_container_t[]              > line_status;
};

template <> struct stream_input_buffer_set<is_not_compressed> {
    cuda::memory::device::unique_ptr< ship_date_t[]      > ship_date;
    cuda::memory::device::unique_ptr< discount_t[]       > discount;
    cuda::memory::device::unique_ptr< extended_price_t[] > extended_price;
    cuda::memory::device::unique_ptr< tax_t[]            > tax;
    cuda::memory::device::unique_ptr< quantity_t[]       > quantity;
    cuda::memory::device::unique_ptr< return_flag_t[]    > return_flag;
    cuda::memory::device::unique_ptr< line_status_t[]    > line_status;
};


// Note: This will force casts to int. It's not a problem
// the way our code is written, but otherwise it needs to be generalized
constexpr inline int div_rounding_up(const int& dividend, const int& divisor)
{
    // This is not the fastest implementation, but it's safe, in that there's never overflow
#if __cplusplus >= 201402L
    std::div_t div_result = std::div(dividend, divisor);
    return div_result.quot + !(!div_result.rem);
#else
    // Hopefully the compiler will optimize the two calls away.
    return std::div(dividend, divisor).quot + !(!std::div(dividend, divisor).rem);
#endif
}

template <typename UniquePtr>
void load_column_from_binary_file(
    UniquePtr&          buffer,
    cardinality_t       cardinality,
    const string&  directory,
    const string&  file_name)
{
    // TODO: C++'ify the file access (will also guarantee exception safety)
    using raw_ptr_type = typename std::decay<decltype(buffer.get())>::type;
    using element_type = typename std::remove_pointer<raw_ptr_type>::type;
    auto file_path = join_path(directory, file_name);
    buffer = std::make_unique<element_type[]>(cardinality);
    cout << "Loading a column from " << file_path << " ... " << flush;
    FILE* pFile = fopen(file_path.c_str(), "rb");
    if (pFile == nullptr) { throw std::runtime_error("Failed opening file " + file_path); }
    auto num_elements_read = fread(buffer.get(), sizeof(element_type), cardinality, pFile);
    if (num_elements_read != cardinality) {
        throw std::runtime_error("Failed reading sufficient data from " +
            file_path + " : expected " + std::to_string(cardinality) + " elements but read only " + std::to_string(num_elements_read) + "."); }
    fclose(pFile);
    cout << "done." << endl;
}

template <typename T>
void write_column_to_binary_file(const T* buffer, cardinality_t cardinality, const string& directory, const string& file_name) {
    auto file_path = join_path(directory, file_name);
    cout << "Writing a column to " << file_path << " ... " << flush;
    FILE* pFile = fopen(file_path.c_str(), "wb+");
    if (pFile == nullptr) { throw std::runtime_error("Failed opening file " + file_path); }
    auto num_elements_written = fwrite(buffer, sizeof(T), cardinality, pFile);
    fclose(pFile);
    if (num_elements_written != cardinality) {
        remove(file_path.c_str());
        throw std::runtime_error("Failed writing all elements to the file - only " +
            std::to_string(num_elements_written) + " written: " + strerror(errno));
    }
    cout << "done." << endl;
}

void print_help(int argc, char** argv) {
    fprintf(stderr, "Unrecognized command line option.\n");
    fprintf(stderr, "Usage: %s [args]\n", argv[0]);
    fprintf(stderr, "   --apply-compression\n");
    fprintf(stderr, "   --print-results\n");
    fprintf(stderr, "   --use-filter-pushdown\n");
    fprintf(stderr, "   --use-coprocessing (currently ignored)\n");
    fprintf(stderr, "   --hash-table-placement=[default:in-registers] (one of: in-registers, local-mem, per-thread-shared-mem, global))\n");
    fprintf(stderr, "   --sf=[default:%f] (number, e.g. 0.01 - 100)\n", defaults::scale_factor);
    fprintf(stderr, "   --streams=[default:%u] (number, e.g. 1 - 64)\n", defaults::num_gpu_streams);
    fprintf(stderr, "   --threads-per-block=[default:%u] (number, e.g. 32 - 1024)\n", defaults::num_threads_per_block);
    fprintf(stderr, "   --tuples-per-thread=[default:%u] (number, e.g. 1 - 1048576)\n", defaults::num_tuples_per_thread);
    fprintf(stderr, "   --tuples-per-kernel=[default:%u] (number, e.g. 64 - 4194304)\n", defaults::num_tuples_per_kernel_launch);
}

template <typename F, typename... Args>
void for_each_argument(F f, Args&&... args) {
    [](...){}((f(std::forward<Args>(args)), 0)...);
}

GPUAggrHashTable aggrs0[num_potential_groups] ALIGN;

#define init_table(ag) memset(&aggrs##ag, 0, sizeof(aggrs##ag))
#define clear(x) memset(x, 0, sizeof(x))

extern "C" void
clear_tables()
{
    init_table(0);
}

void make_sure_we_are_on_cpu_core_0()
{
    // Make sure we are on core 0
    // TODO: Why not in a function?
    cpu_set_t cpuset; 

    CPU_ZERO(&cpuset);
    CPU_SET(0, &cpuset);
    sched_setaffinity(0, sizeof(cpuset), &cpuset);
}

#include "cpu.h"


std::pair<string,string> split_once(string delimited, char delimiter) {
    auto pos = delimited.find_first_of(delimiter);
    return { delimited.substr(0, pos), delimited.substr(pos+1) };
}

template <typename T>
void print_results(const T& aggregates_on_host, cardinality_t cardinality) {
    cout << "+---------------------------------------------------- Results ------------------------------------------------------+\n";
    cout << "|  LS | RF |  sum_quantity        |  sum_base_price      |  sum_disc_price      |  sum_charge          | count      |\n";
    cout << "+-------------------------------------------------------------------------------------------------------------------+\n";
    auto print_dec = [] (auto s, auto x) { printf("%s%17ld.%02ld", s, Decimal64::GetInt(x), Decimal64::GetFrac(x)); };

    for (int group=0; group<num_potential_groups; group++) {
        if (true) { // (aggregates_on_host.record_count[group] > 0) {
            char rf = decode_return_flag(group >> line_status_bits);
            char ls = decode_line_status(group & 0b1);
            if (rf == 'A' and ls == 'F') {
                if (cardinality == 6001215) {
                    assert(aggregates_on_host.sum_quantity[group] == 3773410700);
                    assert(aggregates_on_host.record_count[group] == 1478493);
                }
            } else if (rf == 'N' and ls == 'F') {
                if (cardinality == 6001215) {
                    assert(aggregates_on_host.sum_quantity[group] == 99141700);
                    assert(aggregates_on_host.record_count[group] == 38854);
                }
            } else if (rf == 'N' and ls == 'O') {
                rf = 'N';
                ls = 'O';
                if (cardinality == 6001215) {
                    assert(aggregates_on_host.sum_quantity[group] == 7447604000);
                    assert(aggregates_on_host.record_count[group] == 2920374);
                }
            } else if (rf == 'R' and ls == 'F') {
                if (cardinality == 6001215) {
                    assert(aggregates_on_host.sum_quantity[group]== 3771975300);
                    assert(aggregates_on_host.record_count[group]== 1478870);
                }
            }

            printf("| # %c | %c ", rf, ls);
            print_dec(" | ",  aggregates_on_host.sum_quantity.get()[group]);
            print_dec(" | ",  aggregates_on_host.sum_base_price.get()[group]);
            print_dec(" | ",  aggregates_on_host.sum_discounted_price.get()[group]);
            print_dec(" | ",  aggregates_on_host.sum_charge.get()[group]);
            printf(" | %10u |\n", aggregates_on_host.record_count.get()[group]);
        }
    }

    cout << "+-------------------------------------------------------------------------------------------------------------------+\n";
}

const std::unordered_map<string, cuda::device_function_t> kernels = {
    { "local-mem",             cuda::device_function_t{(void*) &cuda::in_local_mem_ht_tpchQ01} },
    { "in-registers",          cuda::device_function_t{(void*) &cuda::in_registers_ht_tpchQ01} },
    { "per-thread-shared-mem", cuda::thread_in_shared_mem_ht_tpchQ01<> },
//    { "per-block-shared-mem",  cuda::shared_mem_ht_tpchQ01               },
    { "global",                cuda::device_function_t{(void*) &cuda::global_ht_tpchQ01}       },
};

const std::unordered_map<string, cuda::device_function_t> kernels_compressed = {
    { "local-mem",             cuda::device_function_t{(void*) &cuda::in_local_mem_ht_tpchQ01_compressed} },
    { "in-registers",          cuda::device_function_t{(void*) &cuda::in_registers_ht_tpchQ01_compressed} },
    { "per-thread-shared-mem", cuda::thread_in_shared_mem_ht_tpchQ01_compressed<> },
//    { "per-block-shared-mem",  cuda::shared_mem_ht_tpchQ01_compressed               },
    { "global",                cuda::device_function_t{(void*) &cuda::global_ht_tpchQ01_compressed      } },
};

const std::unordered_map<string, cuda::device_function_t> kernels_filter_pushdown = {
    { "local-mem",             cuda::device_function_t{(void*) &cuda::in_local_mem_ht_tpchQ01_filter_pushdown_compressed} },
    { "in-registers",          cuda::device_function_t{(void*) &cuda::in_registers_ht_tpchQ01_filter_pushdown_compressed} },
    { "global",                cuda::device_function_t{(void*) &cuda::global_ht_tpchQ01_filter_pushdown_compressed      } },
};

// Some kernel variants cannot support as many threads per block as the hardware allows generally,
// and for these we use a fixed number for now
const std::unordered_map<string, cuda::grid_block_dimension_t> fixed_threads_per_block = {
    { "per-thread-shared-mem", cuda::max_threads_per_block_for_per_thread_shared_mem },
};



int main(int argc, char** argv) {
    cout << "TPC-H Query 1" << '\n';
    make_sure_we_are_on_cpu_core_0();

    cardinality_t cardinality;

    // Command-line-settable parameters
    double scale_factor              = defaults::scale_factor;
    std::string kernel_variant       = defaults::kernel_variant;
    bool should_print_results        = defaults::should_print_results;
    bool use_filter_pushdown         = false;
    bool apply_compression           = defaults::apply_compression;
    int num_gpu_streams              = defaults::num_gpu_streams;
    cuda::grid_block_dimension_t num_threads_per_block
                                     = defaults::num_threads_per_block;
    int num_tuples_per_thread        = defaults::num_tuples_per_thread;
    int num_tuples_per_kernel_launch = defaults::num_tuples_per_kernel_launch;
        // Make sure it's a multiple of num_threads_per_block and of warp_size, or bad things may happen
    int num_query_execution_runs     = defaults::num_query_execution_runs;
    bool user_set_num_threads_per_block = false;

    // This is the number of times we run the actual query execution - the part that we time;
    // it will not include initialization/allocations that are not necessary when the DBMS
    // is brought up. Note the allocation vs sub-allocation issue (see further comments below)

    //bool apply_compression = true;
    bool use_coprocessing = false;

    for(int i = 1; i < argc; i++) {
        auto arg = string(argv[i]);
        if (arg.substr(0,2) != "--") {
            print_help(argc, argv);
            exit(EXIT_FAILURE);
        }
        arg = arg.substr(2);
        if (arg == "device") {
            get_device_properties();
            exit(1);
     //   } else if (arg == "--compress") {
     //       apply_compression = true;
        } else if (arg == "use-coprocessing") {
            use_coprocessing = true;
        } else if (arg == "apply-compression") {
            apply_compression = true;
        } else if (arg == "use-filter-pushdown") {
            use_filter_pushdown = true;
            apply_compression = true;
        }  else if (arg == "print-results") {
            should_print_results = true;
        } else {
            // A  name=value argument
            auto p = split_once(arg, '=');
            auto& arg_name = p.first; auto& arg_value = p.second;
            if (arg_name == "scale-factor") {
                scale_factor = std::stod(arg_value);
                if (scale_factor - 0 < 0.001) {
                    cerr << "Invalid scale factor " + std::to_string(scale_factor) << endl;
					exit(EXIT_FAILURE);
                }
            } else if (arg_name == "hash-table-placement") {
                kernel_variant = arg_value;
                if (kernels.find(kernel_variant) == kernels.end()) {
                    cerr << "No kernel variant named \"" + kernel_variant + "\" is available" << endl;
					exit(EXIT_FAILURE);
                }
            } else if (arg_name == "streams") {
                num_gpu_streams = std::stoi(arg_value);
            } else if (arg_name == "tuples-per-thread") {
                num_tuples_per_thread = std::stoi(arg_value);
            } else if (arg_name == "threads-per-block") {
                num_threads_per_block = std::stoi(arg_value);
                user_set_num_threads_per_block = true;
            } else if (arg_name == "tuples-per-kernel-launch") {
                num_tuples_per_kernel_launch = std::stoi(arg_value);
            } else if (arg_name == "runs") {
                num_query_execution_runs = std::stoi(arg_value);
                if (num_query_execution_runs <= 0) {
                    cerr << "Number of runs must be positive" << endl;
					exit(EXIT_FAILURE);
                }
            } else {
                print_help(argc, argv);
                exit(EXIT_FAILURE);
            }
        }
    }
    if (fixed_threads_per_block.find(kernel_variant) != fixed_threads_per_block.end()) {
        if (user_set_num_threads_per_block and
            (fixed_threads_per_block.at(kernel_variant) != num_threads_per_block)) {
            throw std::invalid_argument("Invalid number of threads per block for kernel variant "
                + kernel_variant + " (it must be " + std::to_string(fixed_threads_per_block.at(kernel_variant)) + ")");
        }
        num_threads_per_block = fixed_threads_per_block.at(kernel_variant);
    }

    lineitem li((size_t)(7000000 * std::max(scale_factor, 1.0)));
        // TODO: lineitem should really not need this cap, it should just adjust
        // allocated space as the need arises (and start with an estimate based on
        // the file size

    std::unique_ptr< ship_date_t[]      > _shipdate;
    std::unique_ptr< return_flag_t[]    > _returnflag;
    std::unique_ptr< line_status_t[]    > _linestatus;
    std::unique_ptr< discount_t[]       > _discount;
    std::unique_ptr< tax_t[]            > _tax;
    std::unique_ptr< extended_price_t[] > _extendedprice;
    std::unique_ptr< quantity_t[]       > _quantity;

    // TODO: Use std::filesystem for the filesystem stuff
    string tpch_directory = join_path("tpch", std::to_string(scale_factor));
    if (file_exists(join_path(tpch_directory, "shipdate.bin"))) {
        // binary files (seem to) exist, load them
        cardinality = filesize(join_path(tpch_directory, "shipdate.bin")) / sizeof(ship_date_t);
        if (cardinality == cardinality_of_scale_factor_1) {
            cardinality = ((double) cardinality) * scale_factor;
        }
        cout << "Lineitem table cardinality for scale factor " << scale_factor << " is " << cardinality << endl;
        if (cardinality == 0) {
            throw std::runtime_error("The lineitem table column cardinality should not be 0");
        }
        load_column_from_binary_file(_shipdate,      cardinality, tpch_directory, "shipdate.bin");
        load_column_from_binary_file(_returnflag,    cardinality, tpch_directory, "returnflag.bin");
        load_column_from_binary_file(_linestatus,    cardinality, tpch_directory, "linestatus.bin");
        load_column_from_binary_file(_discount,      cardinality, tpch_directory, "discount.bin");
        load_column_from_binary_file(_tax,           cardinality, tpch_directory, "tax.bin");
        load_column_from_binary_file(_extendedprice, cardinality, tpch_directory, "extendedprice.bin");
        load_column_from_binary_file(_quantity,      cardinality, tpch_directory, "quantity.bin");

        // See: We don't need no stinkin' macros these days. Actually, we can do something
        // similar with a lot of the replicated code in this file
        for_each_argument(
            [&](auto tup){
                std::get<0>(tup).cardinality = cardinality;
                std::get<0>(tup).m_ptr = std::get<1>(tup).get();
            },
            tie(li.l_shipdate,      _shipdate),
            tie(li.l_returnflag,    _returnflag),
            tie(li.l_linestatus,    _linestatus),
            tie(li.l_discount,      _discount),
            tie(li.l_tax,           _tax),
            tie(li.l_extendedprice, _extendedprice), 
            tie(li.l_quantity,      _quantity)
        );
    } else {
        // TODO: Take this out into a script
        syscall("mkdir -p tpch");
        syscall(string("mkdir -p ") + tpch_directory);
        std::string input_file = join_path(tpch_directory, "lineitem.tbl");
        if (not file_exists(input_file.c_str())) {
            throw std::runtime_error("Cannot locate table text file " + input_file);
            // Not generating it ourselves - that's: 1. Not healthy and 2. Not portable;
            // setup scripts are intended to do that
        }
        cout << "Parsing the lineitem table in file " << input_file << endl;
        li.FromFile(input_file.c_str());
        cardinality = li.l_extendedprice.cardinality;
        if (cardinality == cardinality_of_scale_factor_1) {
            cardinality = ((double) cardinality) * scale_factor;
        }
        if (cardinality == 0) {
            throw std::runtime_error("The lineitem table column cardinality should not be 0");
        }
        cout << "CSV read & parsed; table length: " << cardinality << " records." << endl;
        auto write_to = [&](auto& uptr, const char* filename) {
            using T = typename std::remove_pointer<typename std::decay<decltype(uptr.get())>::type>::type;
            load_column_from_binary_file(uptr.get(), cardinality, tpch_directory, "shipdate.bin");
        };
        write_column_to_binary_file(li.l_shipdate.get(),      cardinality, tpch_directory, "shipdate.bin");
        write_column_to_binary_file(li.l_returnflag.get(),    cardinality, tpch_directory, "returnflag.bin");
        write_column_to_binary_file(li.l_linestatus.get(),    cardinality, tpch_directory, "linestatus.bin");
        write_column_to_binary_file(li.l_discount.get(),      cardinality, tpch_directory, "discount.bin");
        write_column_to_binary_file(li.l_tax.get(),           cardinality, tpch_directory, "tax.bin");
        write_column_to_binary_file(li.l_extendedprice.get(), cardinality, tpch_directory, "extendedprice.bin");
        write_column_to_binary_file(li.l_quantity.get(),      cardinality, tpch_directory, "quantity.bin");    
    }


    clear_tables(); // currently only used by the CPU implementation
    CoProc* cpu = use_coprocessing ?  new CoProc(li, true) : nullptr;

    auto compressed_ship_date      = cuda::memory::host::make_unique< compressed::ship_date_t[]      >(cardinality);
    auto compressed_discount       = cuda::memory::host::make_unique< compressed::discount_t[]       >(cardinality);
    auto compressed_extended_price = cuda::memory::host::make_unique< compressed::extended_price_t[] >(cardinality);
    auto compressed_tax            = cuda::memory::host::make_unique< compressed::tax_t[]            >(cardinality);
    auto compressed_quantity       = cuda::memory::host::make_unique< compressed::quantity_t[]       >(cardinality);
    auto compressed_return_flag    = cuda::memory::host::make_unique< bit_container_t[] >(div_rounding_up(cardinality, return_flag_values_per_container));
    auto compressed_line_status    = cuda::memory::host::make_unique< bit_container_t[] >(div_rounding_up(cardinality, line_status_values_per_container));
    auto ship_date_bit_vector      = cuda::memory::host::make_unique< uint8_t[] >(div_rounding_up(cardinality, 8));

    // Eyal says: Drop these copies, we really don't need them AFAICT
    auto ship_date      = _shipdate.get();
    auto return_flag    = _returnflag.get();
    auto line_status    = _linestatus.get();
    auto discount       = _discount.get();
    auto tax            = _tax.get();
    auto extended_price = _extendedprice.get();
    auto quantity       = _quantity.get();

    if (apply_compression) {
        cout << "Preprocessing/compressing column data... " << flush;

        // Man, we really need to have a sub-byte-length-value container class
        std::memset(compressed_return_flag.get(), 0, div_rounding_up(cardinality, return_flag_values_per_container));
        std::memset(compressed_line_status.get(), 0, div_rounding_up(cardinality, line_status_values_per_container));
        for(cardinality_t i = 0; i < cardinality; i++) {
            compressed_ship_date[i]      = ship_date[i] - ship_date_frame_of_reference;
            compressed_discount[i]       = discount[i]; // we're keeping the factor 100 scaling
            compressed_extended_price[i] = extended_price[i];
            compressed_quantity[i]       = quantity[i] / 100;
            compressed_tax[i]            = tax[i]; // we're keeping the factor 100 scaling
            set_bit_resolution_element<log_return_flag_bits, cardinality_t>(
                compressed_return_flag.get(), i, encode_return_flag(return_flag[i]));
            set_bit_resolution_element<log_line_status_bits, cardinality_t>(
                compressed_line_status.get(), i, encode_line_status(line_status[i]));
            assert( (ship_date_t)      compressed_ship_date[i]      == ship_date[i] - ship_date_frame_of_reference);
            assert( (discount_t)       compressed_discount[i]       == discount[i]);
            assert( (extended_price_t) compressed_extended_price[i] == extended_price[i]);
            assert( (quantity_t)       compressed_quantity[i]       == quantity[i] / 100);
                // not keeping the scaling here since we know the data is all integral; you could call this a form
                // of compression
            assert( (tax_t)            compressed_tax[i]            == tax[i]);
        }
        for(cardinality_t i = 0; i < cardinality; i++) {
            assert(decode_return_flag(get_bit_resolution_element<log_return_flag_bits, cardinality_t>(compressed_return_flag.get(), i)) == return_flag[i]);
            assert(decode_line_status(get_bit_resolution_element<log_line_status_bits, cardinality_t>(compressed_line_status.get(), i)) == line_status[i]);
        }

        cout << "done." << endl;
    }

    // Note:
    // We are not timing the host-side allocations here. In a real DBMS, these will likely only be
    // a few sub-allocations, which would take very little time (dozens of clock cycles overall) -
    // no system calls.

    struct {
        std::unique_ptr<sum_quantity_t[]        > sum_quantity;
        std::unique_ptr<sum_base_price_t[]      > sum_base_price;
        std::unique_ptr<sum_discounted_price_t[]> sum_discounted_price;
        std::unique_ptr<sum_charge_t[]          > sum_charge;
        std::unique_ptr<sum_discount_t[]        > sum_discount;
        std::unique_ptr<cardinality_t[]         > record_count;
        // Why aren't we computing these? They're part of TPC-H Q1 after all
        // struct {
        //     std::unique_ptr<avg_quantity_t[]        > avg_quantity;
        //     std::unique_ptr<avg_extended_price_t[]  > avg_extended_price;
        //     std::unique_ptr<avg_discount_t[]        > avg_discount;
        // } derived;
    } aggregates_on_host = {
        std::make_unique< sum_quantity_t[]         >(num_potential_groups),
        std::make_unique< sum_base_price_t[]       >(num_potential_groups),
        std::make_unique< sum_discounted_price_t[] >(num_potential_groups),
        std::make_unique< sum_charge_t []          >(num_potential_groups),
        std::make_unique< sum_discount_t[]         >(num_potential_groups),
        std::make_unique< cardinality_t[]          >(num_potential_groups)
        // ,
        // {
        //      std::make_unique< avg_quantity_t[]         >(num_potential_groups),
        //      std::make_unique< avg_extended_price_t[]   >(num_potential_groups),
        //      std::make_unique< avg_discount_t[]         >(num_potential_groups),
        // }
    };

    /* Allocate memory on device */
    
    // Note:
    // We are not timing the allocations here. In a real DBMS, actual CUDA allocations would
    // happen with the DBMS is brought up, and when a query is processed, it will only be
    // a few sub-allocations, which would take very little time (dozens of clock cycles overall) -
    // no CUDA API nor system calls. We _will_, however, time the initialization of the buffers.

    auto cuda_device = cuda::device::current::get();

    struct {
        cuda::memory::device::unique_ptr< sum_quantity_t[]         > sum_quantity;
        cuda::memory::device::unique_ptr< sum_base_price_t[]       > sum_base_price;
        cuda::memory::device::unique_ptr< sum_discounted_price_t[] > sum_discounted_price;
        cuda::memory::device::unique_ptr< sum_charge_t[]           > sum_charge;
        cuda::memory::device::unique_ptr< sum_discount_t[]         > sum_discount;
        cuda::memory::device::unique_ptr< cardinality_t[]          > record_count;
    } aggregates_on_device = {
        cuda::memory::device::make_unique< sum_quantity_t[]         >(cuda_device, num_potential_groups),
        cuda::memory::device::make_unique< sum_base_price_t[]       >(cuda_device, num_potential_groups),
        cuda::memory::device::make_unique< sum_discounted_price_t[] >(cuda_device, num_potential_groups),
        cuda::memory::device::make_unique< sum_charge_t []          >(cuda_device, num_potential_groups),
        cuda::memory::device::make_unique< sum_discount_t[]         >(cuda_device, num_potential_groups),
        cuda::memory::device::make_unique< cardinality_t[]          >(cuda_device, num_potential_groups)
    };

    struct {
        std::vector<stream_input_buffer_set<is_not_compressed> > uncompressed;
        std::vector<stream_input_buffer_set<is_compressed    > > compressed;
    } stream_input_buffer_sets;
    std::vector<cuda::stream_t<>> streams;
    if (apply_compression) {
        stream_input_buffer_sets.compressed.reserve(num_gpu_streams);
    } else {
        stream_input_buffer_sets.uncompressed.reserve(num_gpu_streams);
    }
    streams.reserve(num_gpu_streams);
        // We'll be scheduling (most of) our work in a round-robin fashion on all of
        // the streams, to prevent the GPU from idling.


    for (int i = 0; i < num_gpu_streams; ++i) {
        if (apply_compression) {
            auto input_buffers = stream_input_buffer_set<is_compressed>{
                cuda::memory::device::make_unique< compressed::ship_date_t[]      >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< compressed::discount_t[]       >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< compressed::extended_price_t[] >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< compressed::tax_t[]            >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< compressed::quantity_t[]       >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< bit_container_t[]              >(cuda_device, div_rounding_up(num_tuples_per_kernel_launch, return_flag_values_per_container)),
                cuda::memory::device::make_unique< bit_container_t[]              >(cuda_device, div_rounding_up(num_tuples_per_kernel_launch, line_status_values_per_container))
            };
            stream_input_buffer_sets.compressed.emplace_back(std::move(input_buffers));
        }
        else {
            auto input_buffers = stream_input_buffer_set<is_not_compressed>{
                cuda::memory::device::make_unique< ship_date_t[]      >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< discount_t[]       >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< extended_price_t[] >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< tax_t[]            >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< quantity_t[]       >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< return_flag_t[]    >(cuda_device, num_tuples_per_kernel_launch),
                cuda::memory::device::make_unique< line_status_t[]    >(cuda_device, num_tuples_per_kernel_launch),
            };
            stream_input_buffer_sets.uncompressed.emplace_back(std::move(input_buffers));
        }
        auto stream = cuda_device.create_stream(cuda::stream::async);
        streams.emplace_back(std::move(stream));
    }

    // You can't measure this from inside the process - without events, which
    // double copy_time = 0;
    // double computation_time = 0;

    // This only works for the overall time, not for anything else, so it's not a good idea:
     std::ofstream results_file;
     results_file.open("results.csv", std::ios::out);

     cuda::profiling::start();

    for(int run_index = 0; run_index < num_query_execution_runs; run_index++) {
        cout << "Executing query, run " << run_index + 1 << " of " << num_query_execution_runs << "... " << flush;
        if (use_coprocessing) {
             cpu->Clear();
         }
        auto start = timer::now();
        
        auto gpu_end_offset = cardinality;
        if (use_coprocessing) {
             // Split the work between the CPU and the GPU at 50% each
             // TODO: 
             // - Double-check the choice of alignment here
             // - The parameters here are weird
             auto cpu_start_offset = cardinality - cardinality / 20;
             cpu_start_offset = cpu_start_offset - cpu_start_offset % num_tuples_per_kernel_launch;
             auto num_records_for_cpu_to_process = cardinality - cpu_start_offset;
             (*cpu)(cpu_start_offset, num_records_for_cpu_to_process);
             gpu_end_offset = cpu_start_offset;
        } 

        // Initialize the aggregates; perhaps we should do this in a single kernel? ... probably not worth it
        streams[0].enqueue.memset(aggregates_on_device.sum_quantity.get(),         0, num_potential_groups * sizeof(sum_quantity_t));
        streams[0].enqueue.memset(aggregates_on_device.sum_base_price.get(),       0, num_potential_groups * sizeof(sum_base_price_t));
        streams[0].enqueue.memset(aggregates_on_device.sum_discounted_price.get(), 0, num_potential_groups * sizeof(sum_discounted_price_t));
        streams[0].enqueue.memset(aggregates_on_device.sum_charge.get(),           0, num_potential_groups * sizeof(sum_charge_t));
        streams[0].enqueue.memset(aggregates_on_device.sum_discount.get(),         0, num_potential_groups * sizeof(sum_discount_t));
        streams[0].enqueue.memset(aggregates_on_device.record_count.get(),         0, num_potential_groups * sizeof(cardinality_t));

        cuda::event_t aggregates_initialized_event = streams[0].enqueue.event(
            cuda::event::sync_by_blocking, cuda::event::dont_record_timings, cuda::event::not_interprocess);
        for (int i = 1; i < num_gpu_streams; ++i) {
            streams[i].enqueue.wait(aggregates_initialized_event);
            // The other streams also require the aggregates to be initialized before doing any work
        }
        auto stream_index = 0;
        for (size_t offset_in_table = 0;
             offset_in_table < gpu_end_offset;
             offset_in_table += num_tuples_per_kernel_launch,
             stream_index = (stream_index+1) % num_gpu_streams)
        {
            auto num_tuples_for_this_launch = std::min<cardinality_t>(num_tuples_per_kernel_launch, gpu_end_offset - offset_in_table);
            auto num_return_flag_bit_containers_for_this_launch = div_rounding_up(num_tuples_for_this_launch, return_flag_values_per_container);
            auto num_line_status_bit_containers_for_this_launch = div_rounding_up(num_tuples_for_this_launch, line_status_values_per_container);

            // auto start_copy = timer::now();  // This can't work, since copying is asynchronous.
            auto& stream = streams[stream_index];

            if (apply_compression) {
                auto& input_buffers = stream_input_buffer_sets.compressed[stream_index];
                stream.enqueue.copy(input_buffers.discount.get()      , compressed_discount.get()       + offset_in_table, num_tuples_for_this_launch * sizeof(compressed::discount_t));
                stream.enqueue.copy(input_buffers.extended_price.get(), compressed_extended_price.get() + offset_in_table, num_tuples_for_this_launch * sizeof(compressed::extended_price_t));
                stream.enqueue.copy(input_buffers.tax.get()           , compressed_tax.get()            + offset_in_table, num_tuples_for_this_launch * sizeof(compressed::tax_t));
                stream.enqueue.copy(input_buffers.quantity.get()      , compressed_quantity.get()       + offset_in_table, num_tuples_for_this_launch * sizeof(compressed::quantity_t));
                stream.enqueue.copy(input_buffers.return_flag.get()   , compressed_return_flag.get()    + offset_in_table / return_flag_values_per_container, num_return_flag_bit_containers_for_this_launch * sizeof(bit_container_t));
                stream.enqueue.copy(input_buffers.line_status.get()   , compressed_line_status.get()    + offset_in_table / line_status_values_per_container, num_line_status_bit_containers_for_this_launch * sizeof(bit_container_t));
                if (use_filter_pushdown) {
                    auto shipdate_bit_vector = ship_date_bit_vector.get();
                    auto shipdate_compressed = compressed_ship_date.get();
                    size_t target = offset_in_table + num_tuples_for_this_launch;
                    for(size_t i = offset_in_table; i < target; i += 8) {
                        shipdate_bit_vector[i / 8] = 0;
                        for(size_t j = 0; j < std::min((size_t) 8, target - i); j++) {
                            shipdate_bit_vector[i / 8] |= (shipdate_compressed[i + j] < compressed_threshold_ship_date) << j;
                        }
                    }
                    stream.enqueue.copy(input_buffers.ship_date.get()     , shipdate_bit_vector             + offset_in_table / 8, ((num_tuples_for_this_launch + 7) / 8) * sizeof(uint8_t));
                } else {
                    stream.enqueue.copy(input_buffers.ship_date.get()     , compressed_ship_date.get()      + offset_in_table, num_tuples_for_this_launch * sizeof(compressed::ship_date_t));
                }
            }
            else {
                auto& input_buffers = stream_input_buffer_sets.uncompressed[stream_index];
                stream.enqueue.copy(input_buffers.ship_date.get()     , ship_date      + offset_in_table, num_tuples_for_this_launch * sizeof(ship_date_t));
                stream.enqueue.copy(input_buffers.discount.get()      , discount       + offset_in_table, num_tuples_for_this_launch * sizeof(discount_t));
                stream.enqueue.copy(input_buffers.extended_price.get(), extended_price + offset_in_table, num_tuples_for_this_launch * sizeof(extended_price_t));
                stream.enqueue.copy(input_buffers.tax.get()           , tax            + offset_in_table, num_tuples_for_this_launch * sizeof(tax_t));
                stream.enqueue.copy(input_buffers.quantity.get()      , quantity       + offset_in_table, num_tuples_for_this_launch * sizeof(quantity_t));
                stream.enqueue.copy(input_buffers.return_flag.get()   , return_flag    + offset_in_table, num_tuples_for_this_launch * sizeof(return_flag_t));
                stream.enqueue.copy(input_buffers.line_status.get()   , line_status    + offset_in_table, num_tuples_for_this_launch * sizeof(line_status_t));
            }

            auto num_blocks = div_rounding_up(
                    num_tuples_for_this_launch, num_threads_per_block * num_tuples_per_thread);
            // NOTE: If the number of blocks drops below the number of GPU cores, this is definitely useless,
            // and to be on the safe side - twice as many.
            auto launch_config = cuda::make_launch_config(num_blocks, num_threads_per_block);
            // cout << "num_blocks = " << num_blocks << ", num_threads_per_block = " << num_threads_per_block << endl;
            (void) launch_config;

            
            if (use_filter_pushdown) {
                auto& input_buffers = stream_input_buffer_sets.compressed[stream_index];
                auto kernel = kernels_filter_pushdown.at(kernel_variant);
                stream.enqueue.kernel_launch(
                    kernel,
                    launch_config,
                    aggregates_on_device.sum_quantity.get(),
                    aggregates_on_device.sum_base_price.get(),
                    aggregates_on_device.sum_discounted_price.get(),
                    aggregates_on_device.sum_charge.get(),
                    aggregates_on_device.sum_discount.get(),
                    aggregates_on_device.record_count.get(),
                    input_buffers.ship_date.get(),
                    input_buffers.discount.get(),
                    input_buffers.extended_price.get(),
                    input_buffers.tax.get(),
                    input_buffers.quantity.get(),
                    input_buffers.return_flag.get(),
                    input_buffers.line_status.get(),
                    num_tuples_for_this_launch);
            } else if (apply_compression) {
                auto& input_buffers = stream_input_buffer_sets.compressed[stream_index];
                auto kernel = kernels_compressed.at(kernel_variant);
                stream.enqueue.kernel_launch(
                    kernel,
                    launch_config,
                    aggregates_on_device.sum_quantity.get(),
                    aggregates_on_device.sum_base_price.get(),
                    aggregates_on_device.sum_discounted_price.get(),
                    aggregates_on_device.sum_charge.get(),
                    aggregates_on_device.sum_discount.get(),
                    aggregates_on_device.record_count.get(),
                    input_buffers.ship_date.get(),
                    input_buffers.discount.get(),
                    input_buffers.extended_price.get(),
                    input_buffers.tax.get(),
                    input_buffers.quantity.get(),
                    input_buffers.return_flag.get(),
                    input_buffers.line_status.get(),
                    num_tuples_for_this_launch);
            } else {
                auto& input_buffers = stream_input_buffer_sets.uncompressed[stream_index];
                auto kernel = kernels.at(kernel_variant);
                stream.enqueue.kernel_launch(
                    kernel,
                    launch_config,
                    aggregates_on_device.sum_quantity.get(),
                    aggregates_on_device.sum_base_price.get(),
                    aggregates_on_device.sum_discounted_price.get(),
                    aggregates_on_device.sum_charge.get(),
                    aggregates_on_device.sum_discount.get(),
                    aggregates_on_device.record_count.get(),
                    input_buffers.ship_date.get(),
                    input_buffers.discount.get(),
                    input_buffers.extended_price.get(),
                    input_buffers.tax.get(),
                    input_buffers.quantity.get(),
                    input_buffers.return_flag.get(),
                    input_buffers.line_status.get(),
                    num_tuples_for_this_launch);
            }
        }
        std::vector<cuda::event_t> completion_events;
        for(int i = 1; i < num_gpu_streams; i++) {
            auto event = streams[i].enqueue.event();
            completion_events.emplace_back(std::move(event));
        }
        
        // It's probably a better idea to go round-robin on the streams here
        streams[0].enqueue.copy(aggregates_on_host.sum_quantity.get(),         aggregates_on_device.sum_quantity.get(),         num_potential_groups * sizeof(sum_quantity_t));
        streams[0].enqueue.copy(aggregates_on_host.sum_base_price.get(),       aggregates_on_device.sum_base_price.get(),       num_potential_groups * sizeof(sum_base_price_t));
        streams[0].enqueue.copy(aggregates_on_host.sum_discounted_price.get(), aggregates_on_device.sum_discounted_price.get(), num_potential_groups * sizeof(sum_discounted_price_t));
        streams[0].enqueue.copy(aggregates_on_host.sum_charge.get(),           aggregates_on_device.sum_charge.get(),           num_potential_groups * sizeof(sum_charge_t));
        streams[0].enqueue.copy(aggregates_on_host.sum_discount.get(),         aggregates_on_device.sum_discount.get(),         num_potential_groups * sizeof(sum_discount_t));
        streams[0].enqueue.copy(aggregates_on_host.record_count.get(),         aggregates_on_device.record_count.get(),         num_potential_groups * sizeof(cardinality_t));

        // TODO: There's some sort of result stability issue here
/*
        for(int i = 1; i < num_gpu_streams; i++) {
            streams[i].synchronize();
        }
*/
        streams[0].synchronize();

        if (cpu) {
            cpu->wait();

            // merge
            // int group_order[4];
            // group_order[0] = 6;
            // group_order[1] = 4;
            // group_order[2] = 0;
            // group_order[3] = 5;
            size_t idx = 0;
            for (size_t i=0; i<MAX_GROUPS; i++) {
                auto& e = cpu->table[i];
                if (e.count <= 0) {
                    continue;
                }

                // auto group = group_order[idx];

                // #define B(i)  aggrs0[group].i += e.i

                // B(sum_quantity);
                // B(count);
                // B(sum_base_price);
                // B(sum_disc);
                // B(sum_disc_price);
                // B(sum_charge);

                idx++;
            }
            assert_always(idx == 4);
        }

        auto end = timer::now();
        std::chrono::duration<double> duration(end - start);
        cout << "done." << endl;
        results_file << duration.count() << '\n';

        if (should_print_results) {
            print_results(aggregates_on_host, cardinality);
        }
    }
    cuda::profiling::stop();
    results_file.close();
}
