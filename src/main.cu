#include <iostream>
#include <cuda/api_wrappers.h>
#include <vector>
#include <iomanip>

#include "kernel.hpp"
#include "../expl_comp_strat/tpch_kit.hpp"

size_t magic_hash(char rf, char ls) {
    return (((rf - 'A')) - (ls - 'F'));
}

#define GIGA (1024 * 1024 * 1024)
#define MEGA (1024 * 1024)
#define KILO (1024)

using timer = std::chrono::high_resolution_clock;

inline bool file_exists (const std::string& name) {
  struct stat buffer;
  return (stat (name.c_str(), &buffer) == 0);
}

#define INITIALIZE_MEMORY(ptrfunc) { \
    auto _shipdate      = ptrfunc< SHIPDATE_TYPE[]       >(cardinality); \
    auto _discount      = ptrfunc< DISCOUNT_TYPE[]       >(cardinality); \
    auto _extendedprice = ptrfunc< EXTENDEDPRICE_TYPE[]  >(cardinality); \
    auto _tax           = ptrfunc< TAX_TYPE[]            >(cardinality); \
    auto _quantity      = ptrfunc< QUANTITY_TYPE[]       >(cardinality); \
    auto _returnflag    = ptrfunc< RETURNFLAG_TYPE[]     >(cardinality); \
    auto _linestatus    = ptrfunc< LINESTATUS_TYPE[]     >(cardinality); \
    shipdate = _shipdate.get(); \
    discount = _discount.get(); \
    extendedprice = _extendedprice.get(); \
    tax = _tax.get(); \
    quantity = _quantity.get(); \
    returnflag = _returnflag.get(); \
    linestatus = _linestatus.get(); \
    _shipdate.release(); \
    _discount.release(); \
    _extendedprice.release(); \
    _tax.release(); \
    _quantity.release(); \
    _returnflag.release(); \
    _linestatus.release(); \
}


struct Stream {
    cudaStream_t stream;
    size_t size;
#define EXPAND(A) \
    A(shipdate, SHIPDATE_TYPE) \
    A(discount, DISCOUNT_TYPE) \
    A(eprice, EXTENDEDPRICE_TYPE) \
    A(tax, TAX_TYPE) \
    A(quantity, QUANTITY_TYPE) \
    A(rf, RETURNFLAG_TYPE) \
    A(ls, LINESTATUS_TYPE)

#define DECLARE(name, type) type* name;
    EXPAND(DECLARE)
#undef DECLARE

    Stream(size_t siz) {
        size = siz;
        cudaStreamCreate(&stream);
#define ALLOC(name, type) cudaMalloc((void**)&name, size * sizeof(type));
    EXPAND(ALLOC)
#undef ALLOC

    }

    void Sync() {
        cudaStreamSynchronize(stream);
    }

    void Run(AggrHashTable* aggrs) {
        size_t amount_of_blocks = size / (VALUES_PER_THREAD * THREADS_PER_BLOCK) + 1;
        size_t SHARED_MEMORY = 0; //sizeof(AggrHashTableLocal) * 18 * THREADS_PER_BLOCK;
         cuda::global_ht_tpchQ01<<<amount_of_blocks, THREADS_PER_BLOCK, SHARED_MEMORY, stream>>>(
            shipdate, discount, eprice, tax, rf, ls, quantity, aggrs, (u64_t) size);
    }

    ~Stream() {
        Sync();
        cudaStreamDestroy(stream);
#define DEALLOC(name, type) cudaFree((void**)name);
    EXPAND(DEALLOC)
#undef DEALLOC

    }
};

struct StreamManager {
private:
    std::vector<Stream> streams;
    size_t pos;

public:
    StreamManager(size_t size, size_t max_streams) {
        streams.reserve(max_streams);
        for (size_t i=0; i<max_streams; i++) {
            streams.emplace_back(size);    
        }
        pos = 0;
    }

    Stream& GetNewStream() {
        return streams[pos++ % streams.size()];
    }
};



int main(int argc, char** argv) {
    if (!file_exists("lineitem.tbl")) {
        fprintf(stderr, "lineitem.tbl not found!\n");
        exit(1);
    }
    std::cout << "TPC-H Query 1" << '\n';
    get_device_properties();
    /* load data */
    auto start_csv = timer::now();
    size_t cardinality;
    lineitem li(7000000ull);
    li.FromFile("lineitem.tbl");
    auto end_csv = timer::now();
    kernel_prologue();

    bool USE_PINNED_MEMORY = true;

    for(int i = 0; i < argc; i++) {
        auto arg = std::string(argv[i]);
        if (arg == "--no-pinned-memory") {
            USE_PINNED_MEMORY = false;
        }
    }

    auto size_per_tuple = sizeof(SHIPDATE_TYPE) + sizeof(DISCOUNT_TYPE) + sizeof(EXTENDEDPRICE_TYPE) + sizeof(TAX_TYPE) + sizeof(QUANTITY_TYPE) + sizeof(RETURNFLAG_TYPE) + sizeof(LINESTATUS_TYPE);

    auto start_preprocess = timer::now();

    SHIPDATE_TYPE* shipdate;
    DISCOUNT_TYPE* discount;
    EXTENDEDPRICE_TYPE* extendedprice;
    TAX_TYPE* tax;
    QUANTITY_TYPE* quantity;
    RETURNFLAG_TYPE* returnflag;
    LINESTATUS_TYPE* linestatus;
    if (USE_PINNED_MEMORY) {
        INITIALIZE_MEMORY(cuda::memory::host::make_unique);
    } else {
        INITIALIZE_MEMORY(std::make_unique);
    }

    for(size_t i = 0; i < cardinality; i++) {
        shipdate[i]      = _shipdate[i] - SHIPDATE_MIN;
        discount[i]      = _discount[i];
        extendedprice[i] = _extendedprice[i];
        linestatus[i]    = _linestatus[i];
        returnflag[i]    = _returnflag[i];
        quantity[i]      = _quantity[i] / 100;
        tax[i]           = _tax[i];

        assert((int)shipdate[i]           == _shipdate[i] - SHIPDATE_MIN);
        assert((int64_t) discount[i]      == _discount[i]);
        assert((int64_t) extendedprice[i] == _extendedprice[i]);
        assert((char) linestatus[i]       == _linestatus[i]);
        assert((char) returnflag[i]       == _returnflag[i]);
        assert((int64_t) quantity[i]      == _quantity[i] / 100);
        assert((int64_t) tax[i]           == _tax[i]);
    }
    auto end_preprocess = timer::now();

    assert(cardinality > 0 && "Prevent BS exception");
    const size_t data_length = cardinality;
    clear_tables();

    /* Allocate memory on device */
    auto current_device = cuda::device::current::get();
    auto d_aggregations  = cuda::memory::device::make_unique< AggrHashTable[]      >(current_device, MAX_GROUPS);

    cudaMemset(d_aggregations.get(), 0, sizeof(AggrHashTable)*MAX_GROUPS);

    double copy_time = 0;
    double computation_time = 0;

    auto start = timer::now();

    {
        StreamManager streams(MAX_TUPLES_PER_STREAM, 8);
        cuda_check_error();
        size_t offset = 0;
        size_t id = 0;

        while (offset < data_length) {
            size_t size = std::min((size_t) MAX_TUPLES_PER_STREAM, (size_t) (data_length - offset));

            if (id < 3 && size > MIN_TUPLES_PER_STREAM) {
                size = std::min((size_t) MIN_TUPLES_PER_STREAM, (size_t) (data_length - offset));
            }

            auto& stream = streams.GetNewStream();

            cuda::memory::async::copy(stream.shipdate, shipdate      + offset, size * sizeof(SHIPDATE_TYPE),     stream.stream);
            cuda::memory::async::copy(stream.discount, discount      + offset, size * sizeof(DISCOUNT_TYPE), stream.stream);
            cuda::memory::async::copy(stream.eprice, extendedprice   + offset, size * sizeof(EXTENDEDPRICE_TYPE), stream.stream);
            cuda::memory::async::copy(stream.tax, tax                + offset, size * sizeof(TAX_TYPE), stream.stream);
            cuda::memory::async::copy(stream.quantity, quantity      + offset, size * sizeof(QUANTITY_TYPE), stream.stream);
            cuda::memory::async::copy(stream.rf, returnflag          + offset, size * sizeof(RETURNFLAG_TYPE),    stream.stream);
            cuda::memory::async::copy(stream.ls, linestatus          + offset, size * sizeof(LINESTATUS_TYPE),    stream.stream);

            stream.Run(d_aggregations.get());

            offset += size;
        }
    }
#if 0
+--------------------------------- Results -------------------------------------+
| # A|F | 3775189380.0 | 5660869596562.20 | 537782526840245.51 | 22063606742391.34|148050313
| # N|O | 7436420042.0 | 11150901563909.83 | 1059336243097923.30 | 43356696188178.99|291624201
| # N|F | 98554592.0 | 147773414130.5 | 14038716137845.53 | 559629940888.35|3864648
| # R|F | 3775791821.0 | 5661703040583.64 | 537860853669941.8 | 21965858049188.54|148069804

# A|F|3775127758.0|5660776097194.45|537773639818393.74|55928474295159270.26|148047881
# N|F|98553062.0|147771098385.98|14038496596503.48|1459997930327758.29|3864590
# N|O|7436302976.0|11150725681373.59|1059319530823485.23|-74298118255258961.-49|291619617
# R|F|3775724970.0|5661603032745.34|537851356391540.97|55936622526669161.61|148067261

#endif
    cuda_check_error();
    cudaDeviceSynchronize();
    cuda::memory::copy(aggrs0, d_aggregations.get(), sizeof(AggrHashTable)*MAX_GROUPS);

    auto end = timer::now();    
    std::cout << "\n"
                 "+--------------------------------------------------- Results ---------------------------------------------------+\n";
    std::cout << "|  LS | RF | sum_quantity        | sum_base_price      | sum_disc_price      | sum_charge          | count      |\n";
    std::cout << "+---------------------------------------------------------------------------------------------------------------+\n";
    auto print_dec = [] (auto s, auto x) { printf("%s%16ld.%02ld", s, Decimal64::GetInt(x), Decimal64::GetFrac(x)); };
    for (size_t group=0; group<MAX_GROUPS; group++) {
        if (aggrs0[group].count > 0) {
            size_t i = group;
            char rf = '-', ls = '-';
            if (group == magic_hash('A', 'F')) {
                rf = 'A';
                ls = 'F';
                if (cardinality == 6001215) {
                    assert(aggrs0[i].sum_quantity == 3773410700);
                    assert(aggrs0[i].count == 1478493);
                }
            } else if (group == magic_hash('N', 'F')) {
                rf = 'N';
                ls = 'F';
                if (cardinality == 6001215) {
                    assert(aggrs0[i].sum_quantity == 99141700);
                    assert(aggrs0[i].count == 38854);
                }
            } else if (group == magic_hash('N', 'O')) {
                rf = 'N';
                ls = 'O';
                if (cardinality == 6001215) {
                    assert(aggrs0[i].sum_quantity == 7447604000);
                    assert(aggrs0[i].count == 2920374);
                }
            } else if (group == magic_hash('R', 'F')) {
                rf = 'R';
                ls = 'F';
                if (cardinality == 6001215) {
                    assert(aggrs0[i].sum_quantity == 3771975300);
                    assert(aggrs0[i].count == 1478870);
                }
            }

            printf("| # %c | %c ", rf, ls);
            print_dec(" | ",  aggrs0[i].sum_quantity);
            print_dec(" | ",  aggrs0[i].sum_base_price);
            print_dec(" | ",  aggrs0[i].sum_disc_price);
            print_dec(" | ",  aggrs0[i].sum_charge);
            printf(" | %10llu |\n", aggrs0[i].count);
        }
    }
    std::cout << "+---------------------------------------------------------------------------------------------------------------+\n";

    double sf = cardinality / 6001215.0;
    uint64_t cache_line_size = 128; // bytes
    uint64_t num_loads =  1478493 + 38854 + 2920374 + 1478870 + 6;
    uint64_t num_stores = 19;
    std::chrono::duration<double> duration(end - start);
    uint64_t tuples_per_second               = static_cast<uint64_t>(data_length / duration.count());
    double effective_memory_throughput       = static_cast<double>((tuples_per_second * size_per_tuple) / GIGA);
    double estimated_memory_throughput       = static_cast<double>((tuples_per_second * cache_line_size) / GIGA);
    double effective_memory_throughput_read  = static_cast<double>((tuples_per_second * size_per_tuple) / GIGA);
    double effective_memory_throughput_write = static_cast<double>(tuples_per_second / (size_per_tuple * GIGA));
    double theretical_memory_bandwidth       = static_cast<double>((5505 * 10e06 * (352 / 8) * 2) / 10e09);
    double efective_memory_bandwidth         = static_cast<double>(((data_length * sizeof(SHIPDATE_TYPE)) + (num_loads * size_per_tuple) + (num_loads * num_stores))  / (duration.count() * 10e09));
    double csv_time = std::chrono::duration<double>(end_csv - start_csv).count();
    double pre_process_time = std::chrono::duration<double>(end_preprocess - start_preprocess).count();
    
    std::cout << "\n+------------------------------------------------- Statistics --------------------------------------------------+\n";
    std::cout << "| TPC-H Q01 performance               : ="          << std::fixed 
              << tuples_per_second <<                 " [tuples/sec]" << std::endl;
    std::cout << "| Time taken                          : ~"          << std::setprecision(2)
              << duration.count() <<                  "  [s]"          << std::endl;
    std::cout << "| Estimated time for TPC-H SF100      : ~"          << std::setprecision(2)
              << duration.count() * (100 / sf) <<     "  [s]"          << std::endl;
    std::cout << "| CSV Time                            : ~"          << std::setprecision(2)
              <<  csv_time <<                         "  [s]"          << std::endl;
    std::cout << "| Preprocess Time                     : ~"          << std::setprecision(2)
              <<  pre_process_time <<                 "  [s]"          << std::endl;
    std::cout << "| Copy Time                           : ~"          << std::setprecision(2)
              << copy_time <<                         "  [s]"          << std::endl;
    std::cout << "| Computation Time                    : ~"          << std::setprecision(2)
              << computation_time <<                  "  [s]"          << std::endl;
    std::cout << "| Effective memory throughput (query) : ~"          << std::setprecision(2)
              << effective_memory_throughput <<       "  [GB/s]"       << std::endl;
    std::cout << "| Estimated memory throughput (query) : ~"          << std::setprecision(1)
              << estimated_memory_throughput <<       "  [GB/s]"       << std::endl;
    std::cout << "| Effective memory throughput (read)  : ~"          << std::setprecision(2)
              << effective_memory_throughput_read <<  "  [GB/s]"       << std::endl;
    std::cout << "| Memory throughput (write)           : ~"          << std::setprecision(2)
              << effective_memory_throughput_write << "  [GB/s]"       << std::endl;
    std::cout << "| Theoretical Bandwidth               : ="          << std::setprecision(1)
              << theretical_memory_bandwidth <<       " [GB/s]"       << std::endl;
    std::cout << "| Effective Bandwidth                 : ~"          << std::setprecision(2)
              << efective_memory_bandwidth <<         "  [GB/s]"       << std::endl;
    std::cout << "+---------------------------------------------------------------------------------------------------------------+\n";
}
