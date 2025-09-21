#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef uint8_t bool;
#define true 1
#define false 0

#define SECTOR_SIZE 512
#define FAT12_ENTRY_SIZE 32

typedef struct {
    uint8_t  jump[3];
    char     oem[8];
    uint16_t bytes_per_sector;
    uint8_t  sectors_per_cluster;
    uint16_t reserved_sectors;
    uint8_t  num_fats;
    uint16_t root_entries;
    uint16_t total_sectors_short;
    uint8_t  media_descriptor;
    uint16_t sectors_per_fat;
    uint16_t sectors_per_track;
    uint16_t num_heads;
    uint32_t hidden_sectors;
    uint32_t total_sectors_long;
    // Extended Boot Record fields
    uint8_t  physical_drive_number;
    uint8_t  reserved1;
    uint8_t  extended_boot_signature;
    uint32_t volume_id;
    char     volume_label[11];
    char     file_system_type[8];
} __attribute__((packed)) fat12_boot_sector_t;

typedef struct {
    char     filename[8];         // File name
    char     ext[3];              // File extension
    uint8_t  attr;                // File attributes
    uint8_t  reserved;            // Reserved for Windows NT
    uint8_t  creation_time_tenths;// Creation time (tenths of second)
    uint16_t creation_time;       // Creation time
    uint16_t creation_date;       // Creation date
    uint16_t last_access_date;    // Last access date
    uint16_t high_first_cluster;  // High word of first cluster (FAT32, 0 for FAT12/16)
    uint16_t last_mod_time;       // Last modification time
    uint16_t last_mod_date;       // Last modification date
    uint16_t first_cluster;       // Low word of first cluster
    uint32_t file_size;           // File size in bytes
} __attribute__((packed)) fat12_dir_entry_t;

fat12_boot_sector_t g_BootSector;
uint8_t* g_FAT = NULL;
fat12_dir_entry_t* g_RootDirectory = NULL;
uint32_t g_RootDirectoryEnd;

// Read boot sector
bool readBootSector(FILE *disk) {
    return fread(&g_BootSector, sizeof(g_BootSector), 1, disk) > 0;
}

// Read sectors from image
bool readSectors(FILE *disk, uint32_t lba, uint32_t count, void *bufferout) {
    bool ok = true;
    ok = ok && (fseek(disk, lba * g_BootSector.bytes_per_sector, SEEK_SET) == 0);
    ok = ok && (fread(bufferout, g_BootSector.bytes_per_sector, count, disk) == count);
    return ok;
}

// Read FAT table
bool readFAT(FILE *disk) {
    g_FAT = (uint8_t*) malloc(g_BootSector.sectors_per_fat * g_BootSector.bytes_per_sector);
    return readSectors(disk, g_BootSector.reserved_sectors, g_BootSector.sectors_per_fat, g_FAT);
}

// Read root directory
bool readRootDirectory(FILE *disk) {
    uint32_t lba = g_BootSector.reserved_sectors + (g_BootSector.num_fats * g_BootSector.sectors_per_fat);
    uint32_t size = sizeof(fat12_dir_entry_t) * g_BootSector.root_entries;
    uint32_t sectors = size / g_BootSector.bytes_per_sector;
    if (size % g_BootSector.bytes_per_sector > 0) sectors++;

    g_RootDirectoryEnd = lba + sectors;
    g_RootDirectory = (fat12_dir_entry_t*) malloc(sectors * g_BootSector.bytes_per_sector);
    return readSectors(disk, lba, sectors, g_RootDirectory);
}

// Find file in root directory
fat12_dir_entry_t* findFile(const char *name){
    for (uint32_t i = 0; i < g_BootSector.root_entries; i++) {
        if (memcmp(name, g_RootDirectory[i].filename, 11) == 0) {
            return &g_RootDirectory[i];
        }
        }
        return NULL;
    }

// Read file contents
bool readFile(fat12_dir_entry_t* fileEntry, FILE *disk, uint8_t *outputBuffer) {
    bool ok = true;
    uint16_t currentCluster = fileEntry->first_cluster;

    do {
        uint32_t lba = g_RootDirectoryEnd + (currentCluster - 2) * g_BootSector.sectors_per_cluster;
        ok = ok && readSectors(disk, lba, g_BootSector.sectors_per_cluster, outputBuffer);
        outputBuffer += g_BootSector.sectors_per_cluster * g_BootSector.bytes_per_sector;
        uint32_t fatIndex = currentCluster + (currentCluster / 2);
        if (currentCluster % 2 == 0) {
            currentCluster = (*(uint16_t*) (g_FAT + fatIndex)) & 0x0FFF;
        } else {
            currentCluster = (*(uint16_t*) (g_FAT + fatIndex)) >> 4;
        }

    } while(ok && currentCluster < 0xFF8);
        return ok;
    }

// Read sector from image
int read_sector(FILE *img, uint32_t lba, uint8_t *buffer) {
    if (fseek(img, lba * SECTOR_SIZE, SEEK_SET) != 0) return -1;
    return fread(buffer, 1, SECTOR_SIZE, img) == SECTOR_SIZE ? 0 : -1;
}

// Find file in root directory
int find_file(FILE *img, fat12_boot_sector_t *bs, const char *name, fat12_dir_entry_t *result) {
    uint32_t root_dir_start = (bs->reserved_sectors + bs->num_fats * bs->sectors_per_fat) * SECTOR_SIZE;
    fseek(img, root_dir_start, SEEK_SET);

    char fname[11] = {0};
    // Format name to 8.3
    int i = 0, j = 0;
    while (name[i] && j < 8 && name[i] != '.') fname[j++] = toupper(name[i++]);
    while (j < 8) fname[j++] = ' ';
    if (name[i] == '.') i++;
    int k = 0;
    while (name[i] && k < 3) fname[8 + k++] = toupper(name[i++]);
    while (k < 3) fname[8 + k++] = ' ';

    for (int idx = 0; idx < bs->root_entries; idx++) {
        fat12_dir_entry_t entry;
        fread(&entry, sizeof(entry), 1, img);

        if (entry.filename[0] == 0x00) break; // End of entries
        if ((uint8_t)entry.filename[0] == 0xE5) continue; // Deleted

        char entry_name[11];
        memcpy(entry_name, entry.filename, 8);
        memcpy(entry_name + 8, entry.ext, 3);

        if (memcmp(fname, entry_name, 11) == 0) {
            memcpy(result, &entry, sizeof(entry));
            return 0;
        }
    }
    return -1; // Not found
}

// Read FAT table into memory
uint8_t* read_fat(FILE *img, fat12_boot_sector_t *bs) {
    uint32_t fat_start = bs->reserved_sectors * SECTOR_SIZE;
    uint32_t fat_size = bs->sectors_per_fat * SECTOR_SIZE;
    uint8_t *fat = malloc(fat_size);
    if (!fat) return NULL;
    fseek(img, fat_start, SEEK_SET);
    if (fread(fat, 1, fat_size, img) != fat_size) {
        free(fat);
        return NULL;
    }
    return fat;
}

// Get next cluster from FAT12 table
uint16_t get_fat_entry(uint8_t *fat, uint16_t cluster) {
    uint32_t offset = cluster + (cluster / 2);
    uint16_t value;
    if (cluster & 1) {
        value = ((fat[offset] >> 4) | (fat[offset + 1] << 4)) & 0xFFF;
    } else {
        value = (fat[offset] | ((fat[offset + 1] & 0x0F) << 8)) & 0xFFF;
    }
    return value;
}

// Read file contents following FAT chain
int read_file(FILE *img, fat12_boot_sector_t *bs, fat12_dir_entry_t *entry, uint8_t *fat, uint8_t *buffer) {
    uint32_t data_start = bs->reserved_sectors + bs->num_fats * bs->sectors_per_fat + ((bs->root_entries * FAT12_ENTRY_SIZE) / SECTOR_SIZE);
    uint16_t cluster = entry->first_cluster;
    uint32_t bytes_read = 0;
    uint32_t file_size = entry->file_size;
    uint32_t cluster_size = bs->sectors_per_cluster * SECTOR_SIZE;

    while (cluster >= 2 && cluster < 0xFF8 && bytes_read < file_size) {
        uint32_t lba = data_start + (cluster - 2) * bs->sectors_per_cluster;
        uint8_t sector[SECTOR_SIZE];
        for (int s = 0; s < bs->sectors_per_cluster; s++) {
            if (read_sector(img, lba + s, sector) != 0) return -1;
            uint32_t to_copy = SECTOR_SIZE;
            if (bytes_read + SECTOR_SIZE > file_size)
                to_copy = file_size - bytes_read;
            memcpy(buffer + bytes_read, sector, to_copy);
            bytes_read += to_copy;
            if (bytes_read >= file_size) break;
        }
        cluster = get_fat_entry(fat, cluster);
    }
    return bytes_read;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("Usage: %s <disk.img> <filename>\n", argv[0]);
        return -1;
    }

    FILE *disk = fopen(argv[1], "rb");
    if (!disk) {
        fprintf(stderr, "Failed to open disk image %s!\n", argv[1]);
        return -1;
    }

    if (!readBootSector(disk)) {
        fprintf(stderr, "Failed to read boot sector\n");
        return -2;
    }

    if (!readFAT(disk)) {
        fprintf(stderr, "Failed to read FAT table\n");
        free(g_FAT);
        return -3;
    }

    if (!readRootDirectory(disk)) {
        fprintf(stderr, "Failed to read root directory\n");
        free(g_FAT);
        free(g_RootDirectory);
        return -4;
    }

    fat12_dir_entry_t *fileEntry = findFile(argv[2]);
    if (!fileEntry) {
        printf("File not found: %s\n", argv[2]);
        free(g_FAT);
        free(g_RootDirectory);
        return -5;
    }

    uint8_t *fileBuffer = (uint8_t*) malloc(fileEntry->file_size + g_BootSector.bytes_per_sector);
    if (!readFile(fileEntry, disk, fileBuffer)) {
        fprintf(stderr, "Could not read file %s!\n", argv[2]);
        free(g_FAT);
        free(g_RootDirectory);
        free(fileBuffer);
        return -6;
    }

    for (size_t i = 0; i < fileEntry->file_size; i++) {
        if (isprint(fileBuffer[i]))
            fputc(fileBuffer[i], stdout);
        else
            printf("<%02x>", fileBuffer[i]);
    }
    fputc('\n', stdout);

/*                        */
/* Copilot Implementation */
/*                        */

/* 

    uint8_t sector[SECTOR_SIZE];
    if (read_sector(disk, 0, sector) != 0) {
        printf("Failed to read boot sector\n");
        fclose(disk);
        return 1;
    }

    fat12_boot_sector_t *bs = (fat12_boot_sector_t *)sector;

    fat12_dir_entry_t entry;
    if (find_file(disk, bs, argv[2], &entry) != 0) {
        printf("File not found: %s\n", argv[2]);
        fclose(disk);
        return 1;
    }

    printf("Found file: %.8s.%.3s, size: %u bytes\n", entry.filename, entry.ext, entry.file_size);

    uint8_t *fat = read_fat(disk, bs);
    if (!fat) {
        printf("Failed to read FAT\n");
        fclose(disk);
        return 1;
    }

    uint8_t *buffer = malloc(entry.file_size);
    if (!buffer) {
        printf("Memory allocation failed\n");
        free(fat);
        fclose(disk);
        return 1;
    }

    int bytes = read_file(disk, bs, &entry, fat, buffer);
    if (bytes <= 0) {
        printf("Failed to read file contents\n");
        free(buffer);
        free(fat);
        fclose(disk);
        return 1;
    }

    printf("File contents (hex):\n");
    for (int i = 0; i < bytes; i++) {
        printf("%02X ", buffer[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    printf("\n");

    free(buffer);
    free(fat);
    fclose(disk);
    return 0;

*/

    free(g_FAT);
    free(g_RootDirectory);
    free(fileBuffer);
    return 0;

}