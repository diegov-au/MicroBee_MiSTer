#include <iostream>
#include <queue>
#include <string>
#include <cstring>
#include <cstdlib>

#include "sim_blkdevice.h"
#include "sim_console.h"

#ifndef _MSC_VER
#else
#define WIN32
#endif


static DebugConsole console;

IData* sd_lba[kVDNUM]= {NULL,NULL,NULL,NULL,NULL,
                   NULL,NULL,NULL,NULL,NULL};
CData* sd_rd=NULL;           // 2-bit in MacLC
CData* sd_wr=NULL;           // 2-bit in MacLC
CData* sd_ack=NULL;          // 2-bit in MacLC
SData* sd_buff_addr=NULL;    // 9-bit byte address within a 512-byte sector
CData* sd_buff_dout=NULL;    // 8-bit (hps_io WIDE=0)
CData* sd_buff_din[kVDNUM]= {NULL,NULL,NULL,NULL,NULL,
                   NULL,NULL,NULL,NULL,NULL};  // 16-bit for MacLC
CData* sd_buff_wr=NULL;
CData* img_mounted=NULL;     // 2-bit in MacLC
CData* img_readonly=NULL;
QData* img_size=NULL;


#define bitset(byte,nbit)   ((byte) |=  (1<<(nbit)))
#define bitclear(byte,nbit) ((byte) &= ~(1<<(nbit)))
#define bitflip(byte,nbit)  ((byte) ^=  (1<<(nbit)))
#define bitcheck(byte,nbit) ((byte) &   (1<<(nbit)))

// This model ticks once per clk_sys edge, so every delay below is in clk_sys
// ticks - but what they model is real time (an SD round-trip, a mount), which
// must not change when the harness changes its master clock. The constants were
// tuned against the 54 MHz hardware rate, so they are quoted in those units and
// scaled to whatever rate we actually run at.
//
// Miss this and the disk shifts relative to the CPU by exactly the clock ratio.
// It is not theoretical: it moved the raftaway_river regression screenshot when
// clk_sys first dropped to 13.5 MHz, while the already-settled arcade banner
// stayed byte-identical - which is precisely why that hash is in the suite.
static int blkdev_clk_sys_hz = 54000000;
void SimBlockDevice_SetClockHz(int hz) { if (hz > 0) blkdev_clk_sys_hz = hz; }
#define HW_TICKS(n) ((int)((long long)(n) * blkdev_clk_sys_hz / 54000000LL))

// Sector-read latency, in block-device ticks, before sd_ack/data is returned.
// Models the real HPS/SD round-trip.  The original 1200 is ~25x too fast: the
// double-buffer prefetch (kicked at byte 20 of each 512-byte block) finishes
// before the block boundary, so the target's io_busy never holds REQ low there
// and the disk driver's inter-block wait loop hangs in sim while real hardware
// (slow SD) shows the REQ-low window and proceeds.  Override with
// +blkdev_latency=<n> to sweep.  Default chosen large enough that the ~492-byte
// read-ahead cannot hide it, so io_busy produces the same window as the FPGA.
static int blkdev_read_latency() {
    static int v = -1;
    if (v < 0) {
        v = 16000;
        const char* m = Verilated::commandArgsPlusMatch("blkdev_latency=");
        if (m && m[0]) { const char* eq = strchr(m, '='); if (eq) v = atoi(eq + 1); }
        // The override is in the same 54 MHz-equivalent units as the default, so
        // a value found by sweeping transfers between harness clock rates.
        v = HW_TICKS(v);
        fprintf(stderr, "blkdev sector-read latency = %d ticks (clk_sys %d Hz)\n",
                v, blkdev_clk_sys_hz);
    }
    return v;
}


void SimBlockDevice::MountDisk( std::string file, int index) {
        disk[index].open(file.c_str(), std::ios::in | std::ios::out | std::ios::binary | std::ios::ate);
        if (!disk[index]) {
                disk[index].clear();
                disk[index].open(file.c_str(), std::ios::in | std::ios::binary | std::ios::ate);
        }
        if (disk[index]) {
                fprintf(stderr,"we are here\n");
           // we shouldn't do the actual mount here..
           disk_size[index]= disk[index].tellg();
        //fprintf(stderr,"mount size %ld\n",disk_size[index]);
           disk[index].seekg(0);
           mountQueue[index]=1;
           printf("disk %d inserted (%s)\n",index,file.c_str());
        }else {
                fprintf(stderr,"some kind of error: %s\n",file.c_str());
        }

}


void SimBlockDevice::BeforeEval(uint64_t cycles)
{
//
// switch to a new disk if current_disk is -1
// check to see if we need a read or a write or a mount
//

// wait until the computer boots to start mounting, etc
 if (cycles < (uint64_t)HW_TICKS(2000)) return;

 for (int i=0; i<kVDNUM;i++)
 {

   //if (current_disk == 0)
   //fprintf(stderr,"current_disk = %d *sd_rd %x ack_delay %x reading %d writing %d\n",current_disk,*sd_rd,ack_delay,reading,writing);

    if (current_disk == i) {
    // send data - one byte at a time (hps_io WIDE=0)
    if (ack_delay==1) {
      if (reading && (*sd_buff_wr==0) &&  (bytecnt<kBLKSZ)) {
         int byte1 = disk[i].get();
         *sd_buff_dout = (unsigned char)(byte1 & 0xFF);
         *sd_buff_addr = bytecnt;
         bytecnt += 1;
         *sd_buff_wr= 1;
      } else if(writing && bytecnt < kBLKSZ) {
        // Write one byte per clock from the target's sector buffer. q_a is
        // synchronous, so the next address is driven after consuming this byte.
        unsigned char byte1 = *(sd_buff_din[i]);
        if (!Verilated::commandArgsPlusMatch("ignore_disk_writes")) {
          disk[i].put(byte1);
        }
        bytecnt += 1;
        *sd_buff_addr = (bytecnt < kBLKSZ) ? bytecnt : 0;
      } else if(writing) {
        disk[i].flush();
        *sd_buff_addr = 0;
        writing = false;
      } else {
          *sd_buff_wr=0;

          if (reading) {
                if(bytecnt >= kBLKSZ) {
                        reading = 0;
                }
        }
      }
    } else {
          *sd_buff_wr=0;
    }
    }

    // issue a mount if we aren't doing anything, and the img_mounted has no bits set
    if (!reading && !writing && mountQueue[i] && !*img_mounted) {
fprintf(stderr,"mounting.. %d\n",i);
           mountQueue[i]=0;
           *img_size = disk_size[i];
           if (img_readonly) *img_readonly=1;
fprintf(stderr,"img_size .. %llu\n",(unsigned long long)*img_size);
           disk[i].seekg(0);
           bitset(*img_mounted,i);
           ack_delay=HW_TICKS(1200);
    } else if (ack_delay==1 && bitcheck(*img_mounted,i) ) {
fprintf(stderr,"mounting flag cleared  %d\n",i);
        bitclear(*img_mounted,i) ;
        //*img_size = 0;
    } else { if (!reading && !writing && ack_delay>0) ack_delay--; }

    // start reading when sd_rd pulses high
    if ((current_disk==-1 || current_disk==i) && (bitcheck(*sd_rd,i) || bitcheck(*sd_wr,i) )) {
       // set current disk here..
//fprintf(stderr,"setting current disk %d %x ack_delay %x\n",i,*sd_rd,ack_delay);
       current_disk=i;
      if (!ack_delay) {
        int lba = *(sd_lba[i]);
        if (bitcheck(*sd_rd,i)) {
                reading = true;
        }
        if (bitcheck(*sd_wr,i)) {
                writing = true;
        }

        disk[i].clear();
        disk[i].seekg((lba) * kBLKSZ);
        disk[i].seekp((lba) * kBLKSZ);
      //  printf("seek %06X lba: (%x) (%d,%d) drive %d reading %d writing %d ack %x\n", (lba) * kBLKSZ,lba,lba,kBLKSZ,i,reading,writing,*sd_ack);
        bytecnt = 0;
        *sd_buff_addr = 0;
        ack_delay = blkdev_read_latency();
      }
    }

    if (current_disk == i) {
      if (ack_delay==1) {
           bitset(*sd_ack,i);
           //printf("setting sd_ack: %x\n",*sd_ack);
      } else {
           bitclear(*sd_ack,i);
           //printf("clearing sd_ack: %x\n",*sd_ack);
      }
      if((ack_delay > 1) || ((ack_delay == 1) && !reading && !writing))
        ack_delay--;
      if (ack_delay==0 && !reading && !writing)
        current_disk=-1;
    }
  }
}

void SimBlockDevice::AfterEval()
{
}


SimBlockDevice::SimBlockDevice(DebugConsole c) {
        console = c;
        current_disk=-1;

        sd_rd = NULL;
        sd_wr = NULL;
        sd_ack = NULL;
        sd_buff_addr = NULL;
        sd_buff_dout = NULL;
        for (int i=0;i<kVDNUM;i++) {
           sd_lba[i] = NULL;
           sd_buff_din[i] = NULL;
           mountQueue[i]=0;
        }
        sd_buff_wr=NULL;
        img_mounted=NULL;
        img_readonly=NULL;
        img_size=NULL;
}

SimBlockDevice::~SimBlockDevice() {

}
