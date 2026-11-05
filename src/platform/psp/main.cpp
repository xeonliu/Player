/*
 * This file is part of EasyRPG Player.
 *
 * EasyRPG Player is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * EasyRPG Player is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with EasyRPG Player. If not, see <http://www.gnu.org/licenses/>.
 */

#include <pspkernel.h>
#include <pspthreadman.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include "player.h"

#include <cerrno>
#include <sys/types.h>

// newlib for the PSP has no chown and ftruncate. Libraries need them for features the Player does
// not use (setting the owner when extracting LZH archives, writing sound files), so a stub that
// fails cleanly is enough to link them.
extern "C" {
int chown(const char* /* path */, uid_t /* owner */, gid_t /* group */) {
	errno = ENOSYS;
	return -1;
}

int ftruncate(int /* fd */, off_t /* length */) {
	errno = ENOSYS;
	return -1;
}
}

PSP_MODULE_INFO("EasyRPG Player", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER);
// Leave 1 MB of the user memory for the kernel
PSP_HEAP_SIZE_KB(-1024);

namespace {
	// Used when argv[0] does not contain the location of the EBOOT
	constexpr const char* DEFAULT_PROJECT_PATH = "ms0:/PSP/GAME/EasyRPG";

	// The HOME button ends the program
	int ExitCallback(int /* arg1 */, int /* arg2 */, void* /* common */) {
		sceKernelExitGame();
		return 0;
	}

	int CallbackThread(SceSize /* args */, void* /* argp */) {
		int cbid = sceKernelCreateCallback("Exit Callback", ExitCallback, nullptr);
		sceKernelRegisterExitCallback(cbid);
		sceKernelSleepThreadCB();
		return 0;
	}

	void SetupCallbacks() {
		int thid = sceKernelCreateThread("Callback Thread", CallbackThread, 0x11, 0xFA0, 0, nullptr);
		if (thid >= 0) {
			sceKernelStartThread(thid, 0, nullptr);
		}
	}

	std::string GetProjectPath(const char* exe_path) {
		// The EBOOT lives in the game folder, so the game data next to it is found
		if (exe_path == nullptr) {
			return DEFAULT_PROJECT_PATH;
		}
		std::string exe = exe_path;
		auto pos = exe.find_last_of('/');
		if (pos == std::string::npos) {
			return DEFAULT_PROJECT_PATH;
		}
		return exe.substr(0, pos);
	}
}

#ifdef PLAYER_PSP_AUDIO_STATS
// Diagnostic only: how much memory is left for the game, found by allocating until it fails
static void LogHeapSize() {
	static void* blocks[2048];
	size_t count = 0;
	while (count < 2048 && (blocks[count] = std::malloc(64 * 1024)) != nullptr) {
		++count;
	}
	for (size_t i = 0; i < count; ++i) {
		std::free(blocks[i]);
	}
	if (FILE* f = std::fopen("ms0:/PSP/GAME/EasyRPG/memory.txt", "w")) {
		std::fprintf(f, "heap_kb=%u\n", static_cast<unsigned>(count * 64));
		std::fclose(f);
	}
}
#endif

int main(int argc, char* argv[]) {
	SetupCallbacks();
#ifdef PLAYER_PSP_AUDIO_STATS
	LogHeapSize();
#endif

	std::vector<std::string> args(argv, argv + argc);

	args.push_back("--project-path");
	args.push_back(GetProjectPath(argc > 0 ? argv[0] : nullptr));

	// Run Player
	Player::Init(std::move(args));
	Player::Run();

	return Player::exit_code;
}
