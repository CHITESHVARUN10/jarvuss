// macOS process resource counters, including kernel-maintained peak footprint.
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
 if (argc!=2) return 2;
 struct rusage_info_v4 r={0};
 if(proc_pid_rusage(atoi(argv[1]),RUSAGE_INFO_V4,(rusage_info_t *)&r)) return 1;
 mach_timebase_info_data_t tb; mach_timebase_info(&tb);
 printf("{\"rss\":%llu,\"footprint\":%llu,\"peak_footprint\":%llu,\"cpu_ns\":%llu,\"disk_read\":%llu,\"disk_write\":%llu}\n",r.ri_resident_size,r.ri_phys_footprint,r.ri_lifetime_max_phys_footprint,(unsigned long long)((long double)(r.ri_user_time+r.ri_system_time)*tb.numer/tb.denom),r.ri_diskio_bytesread,r.ri_diskio_byteswritten);
 return 0;
}
