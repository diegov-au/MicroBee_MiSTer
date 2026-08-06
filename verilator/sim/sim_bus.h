#pragma once
#include <queue>
#include "verilated.h"
#include "sim_console.h"


#ifndef _MSC_VER
#else
#define WIN32
#endif

struct SimBus_DownloadChunk {
public:
	std::string file;
	int index;
	bool restart;
	
	SimBus_DownloadChunk() {
		file = "";
		index = -1;
	}

	SimBus_DownloadChunk(std::string file, int index) {
		SimBus_DownloadChunk(file, index, false);
	}
	SimBus_DownloadChunk(std::string file, int index, bool restart) {
		this->restart = restart;
		this->file = std::string(file);
		this->index = index;
	}
};

struct SimBus {
public:

	IData* ioctl_addr;
	// 16-bit, matching hps_io and the RTL port. The slot goes on the wire as
	// N<<6, so 8 bits capped the harness at slot 3 and wrapped slot 4 onto slot 0
	// (BUG-004) - a simulation-only failure, which is the dangerous kind.
	SData* ioctl_index;
	CData* ioctl_wait;
	CData* ioctl_download;
	CData* ioctl_upload;
	CData* ioctl_wr;
	CData* ioctl_dout;  // 8-bit (hps_io WIDE=0), as the MicroBee's Z80 bus needs
	CData* ioctl_din;

	void BeforeEval(void);
	void AfterEval(void);
	void QueueDownload(std::string file, int index);
	void QueueDownload(std::string file, int index, bool restart);
	bool HasQueue();

	SimBus(DebugConsole c);
	~SimBus();

private:
	std::queue<SimBus_DownloadChunk> downloadQueue;
	SimBus_DownloadChunk currentDownload;
	void SetDownload(std::string file, int index);
};
