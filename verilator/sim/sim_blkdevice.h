#pragma once
#include <iostream>
#include <fstream>
#include "verilated.h"
#include "sim_console.h"


#ifndef _MSC_VER
#else
#define WIN32
#endif

#define kVDNUM 10
#define kBLKSZ 512

// The model's delays are in clk_sys ticks but represent real time, so they are
// scaled when the harness runs at a master clock other than the 54 MHz hardware
// rate. Call before the first BeforeEval - the read latency is cached on first
// use. See the note in sim_blkdevice.cpp.
void SimBlockDevice_SetClockHz(int hz);

struct SimBlockDevice {
public:

	IData* sd_lba[kVDNUM];
	CData* sd_rd;           // 2-bit in MacLC
	CData* sd_wr;           // 2-bit in MacLC
	CData* sd_ack;          // 2-bit in MacLC
	SData* sd_buff_addr;    // 9-bit byte address within a 512-byte sector
	CData* sd_buff_dout;    // 8-bit (hps_io WIDE=0)
	CData* sd_buff_din[kVDNUM];
	CData* sd_buff_wr;
	CData* img_mounted;     // 2-bit in MacLC
	CData* img_readonly;
	QData* img_size;

	int bytecnt;
        long int disk_size[kVDNUM];
	bool reading;
	bool writing;
	int ack_delay;
	int current_disk;
	bool mountQueue[kVDNUM];
	std::fstream disk[kVDNUM];

	// 64-bit: main_time passes 2^31 after 79 s of emulated time under --fast and
	// only 20 s at 54 MHz. Truncating it to int made this go negative, and the
	// early-out below then returned on every call - the block device died
	// permanently mid-run and every later disk or tape request went unanswered.
	void BeforeEval(uint64_t cycles);
	void AfterEval(void);
	//void QueueDownload(std::string file, int index);
	//void QueueDownload(std::string file, int index, bool restart);
	//bool HasQueue();
	void MountDisk( std::string file, int index);

	SimBlockDevice(DebugConsole c);
	~SimBlockDevice();


private:
	//std::queue<SimBus_DownloadChunk> downloadQueue;
	//SimBus_DownloadChunk currentDownload;
	//void SetDownload(std::string file, int index);
};
