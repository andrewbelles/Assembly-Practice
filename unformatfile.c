#include <stdio.h>
#include <string.h>

#define MAX_CT  16
#define MAX_LEN 64

int main(int argc, char *argv[]) {
  
  // Check argument count
  if (argc < 2 || argc > 17) {
    printf("Invalid Argument Count. Usage: [./exec] [file1.txt] [file2.txt] ...\n");
    return 1;
  }

  char filenames[MAX_CT][MAX_LEN];
  FILE *read, *write;
  double buffer;

  for (int i = 0; i < argc - 1; ++i) {
    read = fopen(argv[i + 1], "r");
    if (read == NULL) {
      printf("Invalid File: %s!\n", argv[i + 1]);
      // If there are more potentially valid files don't exit early just skip
      if (i < argc - 2) continue;
      
      // If last file exit early 
      return 1;
    }
    // Pull file string length 
    int len = strlen(argv[i + 1]);

    // Remove .txt
    argv[i + 1][len - 4] = 0;
  
    // Append .dat to argv and add output to filenames[i] 
    snprintf(filenames[i], MAX_LEN, "%s.dat", argv[i + 1]);

    // Open file in write binary mode 
    write = fopen(filenames[i], "wb");
    if (write == NULL) {
      printf("Invalid File!\n");
      // If there are more potentially valid files don't exit early just skip
      if (i < argc - 2) continue;
      
      // If last file exit early 
      return 1;
    }

    // Iterate through file 
    while (fscanf(read, "%lf", &buffer) != EOF) {
      fwrite(&buffer, sizeof(double), 1, write);
    }

    fclose(write);
    fclose(read);
  }
}
