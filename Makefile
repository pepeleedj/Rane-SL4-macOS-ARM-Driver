CC = clang
ARCH = -arch arm64 -arch x86_64
CFLAGS = -fobjc-arc -O2

all: plugin api panel

plugin:
	$(CC) $(ARCH) -bundle $(CFLAGS) -framework Foundation -framework CoreAudio -framework IOKit -framework IOUSBHost plugin/SL4Device.m -o SL4Device

api:
	$(CC) $(ARCH) -dynamiclib $(CFLAGS) -install_name /Library/Frameworks/SL4Api.framework/Versions/A/SL4Api -current_version 1.1.0 -compatibility_version 1.0.0 -framework Foundation -framework CoreAudio -framework IOKit tools/SL4Api.m -o SL4Api

panel:
	$(CC) $(ARCH) $(CFLAGS) -framework Foundation -framework CoreAudio tools/sl4panel.m -o sl4panel

clean:
	rm -f SL4Device SL4Api sl4panel

.PHONY: all plugin api panel clean
