#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int LZ4_decompress_safe(const char *source, char *dest, int compressed_size,
			int dest_capacity);
int LZ4_compress_HC(const char *source, char *dest, int source_size,
		    int dest_capacity, int compression_level);

static void die(const char *message)
{
	perror(message);
	exit(EXIT_FAILURE);
}

static uint64_t parse_number(const char *text, const char *name)
{
	char *end;
	errno = 0;
	uint64_t number = strtoull(text, &end, 10);
	if (errno || *text == '\0' || *end != '\0') {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		exit(EXIT_FAILURE);
	}
	return number;
}

static size_t count_matches(const unsigned char *haystack, size_t haystack_size,
			    const char *needle, size_t needle_size,
			    unsigned char **match)
{
	size_t count = 0;
	for (size_t i = 0; i + needle_size <= haystack_size; i++) {
		if (memcmp(haystack + i, needle, needle_size) == 0) {
			*match = (unsigned char *)haystack + i;
			count++;
		}
	}
	return count;
}

int main(int argc, char **argv)
{
	if (argc != 7) {
		fprintf(stderr, "usage: %s IMAGE OFFSET CLUSTER_SIZE FILE_SIZE OLD NEW\n",
			argv[0]);
		return EXIT_FAILURE;
	}

	uint64_t offset = parse_number(argv[2], "offset");
	uint64_t cluster_size_u64 = parse_number(argv[3], "cluster size");
	uint64_t file_size_u64 = parse_number(argv[4], "file size");
	if (cluster_size_u64 == 0 || file_size_u64 == 0 ||
	    cluster_size_u64 > INT32_MAX || file_size_u64 > INT32_MAX) {
		fprintf(stderr, "extent is too large\n");
		return EXIT_FAILURE;
	}

	int cluster_size = (int)cluster_size_u64;
	int file_size = (int)file_size_u64;
	size_t old_size = strlen(argv[5]);
	size_t new_size = strlen(argv[6]);
	if (old_size == 0 || old_size != new_size) {
		fprintf(stderr, "OLD and NEW must have the same non-zero length\n");
		return EXIT_FAILURE;
	}

	int fd = open(argv[1], O_RDWR | O_CLOEXEC);
	if (fd < 0)
		die("open image");

	unsigned char *cluster = malloc((size_t)cluster_size);
	unsigned char *plain = malloc((size_t)file_size);
	unsigned char *compressed = calloc(1, (size_t)cluster_size);
	if (!cluster || !plain || !compressed) {
		fputs("could not allocate buffers\n", stderr);
		return EXIT_FAILURE;
	}
	if (pread(fd, cluster, (size_t)cluster_size, (off_t)offset) != cluster_size)
		die("read extent");

	int padding = 0;
	while (padding < cluster_size && cluster[padding] == 0)
		padding++;
	if (padding == cluster_size) {
		fprintf(stderr, "compressed extent is empty\n");
		return EXIT_FAILURE;
	}

	int decoded = LZ4_decompress_safe((char *)cluster + padding, (char *)plain,
				       cluster_size - padding, file_size);
	if (decoded != file_size) {
		fprintf(stderr, "LZ4 decoded %d bytes, expected %d\n", decoded, file_size);
		return EXIT_FAILURE;
	}

	unsigned char *match = NULL;
	size_t old_matches = count_matches(plain, (size_t)file_size,
				   argv[5], old_size, &match);
	size_t new_matches = count_matches(plain, (size_t)file_size,
				   argv[6], new_size, &match);
	if (old_matches == 0 && new_matches == 1) {
		puts("property already patched");
		return EXIT_SUCCESS;
	}
	if (old_matches != 1 || new_matches != 0) {
		fprintf(stderr, "expected one OLD value and no NEW value, found %zu and %zu\n",
			old_matches, new_matches);
		return EXIT_FAILURE;
	}
	memcpy(match, argv[6], new_size);

	int encoded = LZ4_compress_HC((char *)plain, (char *)compressed,
				      file_size, cluster_size, 12);
	if (encoded <= 0 || encoded > cluster_size) {
		fprintf(stderr, "patched extent does not fit in %d bytes\n", cluster_size);
		return EXIT_FAILURE;
	}
	memmove(compressed + cluster_size - encoded, compressed, (size_t)encoded);
	memset(compressed, 0, (size_t)(cluster_size - encoded));
	if (pwrite(fd, compressed, (size_t)cluster_size, (off_t)offset) != cluster_size)
		die("write extent");
	if (fsync(fd) != 0)
		die("sync image");
	if (close(fd) != 0)
		die("close image");

	printf("patched property in %s\n", argv[1]);
	free(compressed);
	free(plain);
	free(cluster);
	return EXIT_SUCCESS;
}
