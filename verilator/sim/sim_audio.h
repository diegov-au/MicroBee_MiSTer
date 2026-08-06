#pragma once

#include <string>
#include "sim_clock.h"

struct SimAudio {
public:

	SimClock clock;
	
	static const unsigned short debug_max_samples = 600;
	float debug_positions[debug_max_samples];
	float debug_wave_l[debug_max_samples];
	float debug_wave_r[debug_max_samples];
	int debug_pos;

	SimAudio(int systemClockFrequency, bool saveToFile);
	~SimAudio();
	// Recompute the decimation divider for a different master clock. Needed
	// because this object is a global, constructed before argv is parsed, and
	// --fast changes clk_sys. Call before Initialise(); harmless otherwise.
	void SetSystemClock(int systemClockFrequency);
	// There is no playback path in here - Clock() only ever decimates and, if
	// asked, appends to a file. Call this before Initialise() to capture the
	// samples. The result is a real WAV: 16-bit PCM mono. The length fields are
	// patched in CleanUp(), so the file is only playable after a clean exit.
	void SetOutputFile(const char* path);
	void Clock(signed short left, signed short right);
	void CollectDebug(signed short left, signed short right);
	void Initialise();
	void CleanUp();
};
