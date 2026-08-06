#include "sim_audio.h"
#include <iostream>
#include <fstream>
#include <string>
#include <list>
//using namespace std;

SimClock clk;
bool outputToFile;
std::ofstream audioFile;
static std::string audioFileName = "audio.wav";
static unsigned int audioRate  = 44100;   // actual rate after integer division
static unsigned int audioBytes = 0;       // payload written so far

//----------------------------------------------------------------------------
// Minimal WAV writer: 16-bit PCM, mono. The length is not known until the run
// ends, so the two size fields are written as placeholders and patched in
// CleanUp() - which means the file is only playable after a clean exit.
//----------------------------------------------------------------------------
static void put32(std::ofstream& f, unsigned int v)
{
	char b[4] = { char(v & 0xFF), char((v >> 8) & 0xFF),
	              char((v >> 16) & 0xFF), char((v >> 24) & 0xFF) };
	f.write(b, 4);
}

static void put16(std::ofstream& f, unsigned int v)
{
	char b[2] = { char(v & 0xFF), char((v >> 8) & 0xFF) };
	f.write(b, 2);
}

static void writeWavHeader(std::ofstream& f, unsigned int rate)
{
	const unsigned int channels = 1, bits = 16;
	f.write("RIFF", 4);
	put32(f, 36);                                   // patched later
	f.write("WAVE", 4);
	f.write("fmt ", 4);
	put32(f, 16);
	put16(f, 1);                                    // PCM
	put16(f, channels);
	put32(f, rate);
	put32(f, rate * channels * bits / 8);           // byte rate
	put16(f, channels * bits / 8);                 // block align
	put16(f, bits);
	f.write("data", 4);
	put32(f, 0);                                    // patched later
}

SimAudio::SimAudio(int systemClockFrequency, bool saveToFile)
{
	SetSystemClock(systemClockFrequency);
	outputToFile = saveToFile;
}

void SimAudio::SetSystemClock(int systemClockFrequency)
{
	int div = systemClockFrequency / 44100;
	clk = SimClock(div);
	// The divider is integer, so the real rate is not exactly 44100 (54 MHz
	// gives 44117.6). Record what it actually is so the WAV header is honest
	// and the pitch comes out right.
	audioRate = div ? (unsigned)(systemClockFrequency / div) : 44100;
}

SimAudio::~SimAudio()
{

}

void SimAudio::SetOutputFile(const char* path)
{
	audioFileName = path;
	outputToFile  = true;
}

void SimAudio::Clock(signed short left, signed short right) {
	clk.Tick();
	if (clk.IsRising()) {
		// 16-bit PCM, left channel only for now.
		if (outputToFile) {
			put16(audioFile, (unsigned short)left);
			audioBytes += 2;
		}
	}
}

void SimAudio::CollectDebug(signed short left, signed short right) {
	float vol_l = left / 32768.0f;
	float vol_r = right / 32768.0f;
	debug_pos++;
	if (debug_pos == debug_max_samples) { debug_pos = 0; }
	debug_wave_l[debug_pos] = vol_l;
	debug_wave_r[debug_pos] = vol_r;

}

void SimAudio::Initialise() {
	// Reset plot data
	for (int c = 0; c < debug_max_samples; c++) {
		debug_wave_l[c] = 0;
		debug_wave_r[c] = 0;
		debug_positions[c] = (double)c / (double)debug_max_samples;
	}
	if (outputToFile)
	{
		// Setup Audio output stream
		audioFile.open(audioFileName.c_str(), std::ios::binary);
		writeWavHeader(audioFile, audioRate);
		audioBytes = 0;
	}
}
void SimAudio::CleanUp() {
	if (outputToFile && audioFile.is_open())
	{
		// Patch the two RIFF length fields now the payload size is known.
		audioFile.seekp(4);
		put32(audioFile, 36 + audioBytes);
		audioFile.seekp(40);
		put32(audioFile, audioBytes);
		audioFile.close();
	}
}

