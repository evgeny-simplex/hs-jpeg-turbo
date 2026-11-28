#include <string.h>
#include "guest.h"

const char *guest_message(const char *text)
{
  static char message[SANDBOX_MESSAGE_SIZE];

  strncpy(message, text, sizeof(message) - 1);
  return message;
}

const char *native_gif_frames(const uint8_t *data, size_t size, uint32_t width, uint32_t height)
{
  Image metadata = {0};

  return frames_animate(data, size, FORMAT_GIF, width, height, &metadata);
}
