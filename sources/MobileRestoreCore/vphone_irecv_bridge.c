#include "vphone_restore_bridge.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libirecovery.h>

struct vphone_irecv_session {
	irecv_client_t client;
	int mode;
};

static int vphone_irecv_mode_matches(int expected_mode, int actual_mode)
{
	switch (expected_mode) {
	case VPHONE_IRECV_MODE_ANY:
		return 1;
	case VPHONE_IRECV_MODE_DFU:
		return (actual_mode == IRECV_K_DFU_MODE) || (actual_mode == IRECV_K_PORT_DFU_MODE);
	case VPHONE_IRECV_MODE_RECOVERY:
		return (actual_mode == IRECV_K_RECOVERY_MODE_1) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_2) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_3) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_4);
	default:
		return 0;
	}
}

static irecv_error_t vphone_irecv_open_checked(irecv_client_t* client, uint64_t ecid, int has_ecid, int expected_mode, int attempts)
{
	irecv_error_t error = irecv_open_with_ecid_and_attempts(client, has_ecid ? ecid : 0, attempts);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	int actual_mode = 0;
	error = irecv_get_mode(*client, &actual_mode);
	if (error != IRECV_E_SUCCESS) {
		irecv_close(*client);
		*client = NULL;
		return error;
	}
	if (!vphone_irecv_mode_matches(expected_mode, actual_mode)) {
		irecv_close(*client);
		*client = NULL;
		return IRECV_E_UNSUPPORTED;
	}

	return IRECV_E_SUCCESS;
}

static irecv_error_t vphone_irecv_send_recovery_file_buffered(irecv_client_t client, const char* path, uint32_t options)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		return IRECV_E_FILE_NOT_FOUND;
	}

	struct stat status;
	if (fstat(fd, &status) != 0) {
		close(fd);
		return IRECV_E_UNKNOWN_ERROR;
	}
	if (status.st_size <= 0) {
		close(fd);
		return IRECV_E_INVALID_INPUT;
	}

	void* buffer = mmap(NULL, (size_t)status.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (buffer == MAP_FAILED) {
		return IRECV_E_UNKNOWN_ERROR;
	}

	irecv_error_t error = irecv_send_buffer(client, buffer, (unsigned long)status.st_size, options);
	munmap(buffer, (size_t)status.st_size);
	return error;
}

const char* vphone_irecv_error_string(int error)
{
	return irecv_strerror((irecv_error_t)error);
}

void* vphone_irecv_open_session(uint64_t ecid, int has_ecid, int mode, int attempts, int* error_out)
{
	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, attempts);
	if (error != IRECV_E_SUCCESS) {
		if (error_out) {
			*error_out = error;
		}
		return NULL;
	}

	struct vphone_irecv_session* session = calloc(1, sizeof(struct vphone_irecv_session));
	if (!session) {
		irecv_close(client);
		if (error_out) {
			*error_out = IRECV_E_OUT_OF_MEMORY;
		}
		return NULL;
	}

	session->client = client;
	session->mode = mode;
	if (error_out) {
		*error_out = IRECV_E_SUCCESS;
	}
	return session;
}

void vphone_irecv_close_session(void* opaque_session)
{
	struct vphone_irecv_session* session = opaque_session;
	if (!session) {
		return;
	}
	if (session->client) {
		irecv_close(session->client);
	}
	free(session);
}

int vphone_irecv_session_send_file(void* opaque_session, const char* path, uint32_t options)
{
	struct vphone_irecv_session* session = opaque_session;
	if (!session || !session->client || !path || !path[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	if (session->mode == VPHONE_IRECV_MODE_RECOVERY) {
		return vphone_irecv_send_recovery_file_buffered(session->client, path, options);
	}
	return irecv_send_file(session->client, path, options);
}

int vphone_irecv_session_send_command(void* opaque_session, const char* command)
{
	struct vphone_irecv_session* session = opaque_session;
	if (!session || !session->client || !command || !command[0]) {
		return IRECV_E_INVALID_INPUT;
	}
	return irecv_send_command(session->client, command);
}

int vphone_irecv_session_send_command_breq(void* opaque_session, const char* command, uint8_t request)
{
	struct vphone_irecv_session* session = opaque_session;
	if (!session || !session->client || !command || !command[0]) {
		return IRECV_E_INVALID_INPUT;
	}
	return irecv_send_command_breq(session->client, command, request);
}

int vphone_irecv_session_usb_control_transfer(void* opaque_session, uint8_t request_type, uint8_t request, uint16_t value, uint16_t index, int timeout_ms)
{
	struct vphone_irecv_session* session = opaque_session;
	if (!session || !session->client) {
		return IRECV_E_INVALID_INPUT;
	}
	return irecv_usb_control_transfer(session->client, request_type, request, value, index, 0, 0, timeout_ms);
}

int vphone_irecv_send_file(const char* path, uint64_t ecid, int has_ecid, int mode, uint32_t options)
{
	if (!path || !path[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 10);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	if (mode == VPHONE_IRECV_MODE_RECOVERY) {
		error = vphone_irecv_send_recovery_file_buffered(client, path, options);
	} else {
		error = irecv_send_file(client, path, options);
	}
	irecv_close(client);
	return error;
}

int vphone_irecv_send_command(const char* command, uint64_t ecid, int has_ecid, int mode)
{
	if (!command || !command[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 10);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	error = irecv_send_command(client, command);
	irecv_close(client);
	return error;
}

int vphone_irecv_send_command_breq(const char* command, uint8_t request, uint64_t ecid, int has_ecid, int mode)
{
	if (!command || !command[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 10);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	error = irecv_send_command_breq(client, command, request);
	irecv_close(client);
	return error;
}

int vphone_irecv_wait_for_mode(uint64_t ecid, int has_ecid, int mode, int timeout_ms)
{
	const useconds_t interval_us = 250000;
	int remaining_ms = timeout_ms;

	while (remaining_ms >= 0) {
		irecv_client_t client = NULL;
		irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 1);
		if (error == IRECV_E_SUCCESS) {
			irecv_close(client);
			return IRECV_E_SUCCESS;
		}
		if (client) {
			irecv_close(client);
		}
		if (remaining_ms == 0) {
			break;
		}
		usleep(interval_us);
		if (remaining_ms < 250) {
			remaining_ms = 0;
		} else {
			remaining_ms -= 250;
		}
	}

	return IRECV_E_TIMEOUT;
}
