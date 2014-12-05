/////////////////////////////////////////////////////////////////////////////////////////
//
// COMS20001 - Assignment 2 
//
//
// Game of Life rules:
// *   any live cell with fewer than two live neighbours dies
// *   any live cell with two or three live neighbours is unaffected
// *   any live cell with more than three live neighbours dies
// *   any dead cell with exactly three live neighbours becomes alive
//
/////////////////////////////////////////////////////////////////////////////////////////

typedef unsigned char uchar;

#include <platform.h>
#include <stdio.h>
#include <math.h>
#include "pgmIO.h"

#define NUM_CORES 5 //THIS GETS SET TO EITHER 3 OR 4 BY THE PREPROCESSOR (DEPENDING ON THE IMAGE SIZE)
#define IMHT 128 //full height of image
#define IMWD 128 //img width
#define MAX_BYTES 640000//871200 //108900        //330x330=108.9kB   = Max size can process with 3 cores
#define FOUR_CORE_BYTES 396900   //230x230=52.9kB    = Max size can process with 4 cores
#define HEIGHT IMHT/NUM_CORES   //the height of a chunk processed by the worker

#define ALIVE 255
#define DEAD 0
#define CELLCOUNT IMHT*IMWD

#define BUTTON_A    14
#define BUTTON_B    13
#define BUTTON_C    11
#define BUTTON_D    7
#define BUTTON_NONE 15

#define MODE_IDLE 0
#define MODE_FARM 1
#define MODE_HARVEST 2
#define MODE_RUNNING 3
#define MODE_PAUSED 4
#define MODE_TERMINATE 5

#define TERMINATE -1    //used by visualiser to tell quads to terminate

#if IMHT*IMWD > MAX_BYTES   //set a flag if this image is too big for the board.
    #define INPUT_TOO_LARGE 1
#else
out port cled0 = PORT_CLOCKLED_0;
out port cled1 = PORT_CLOCKLED_1;
out port cled2 = PORT_CLOCKLED_2;
out port cled3 = PORT_CLOCKLED_3;
#if IMHT*IMWD > FOUR_CORE_BYTES   //too big for 4 cores
    #undef NUM_CORES
    #define NUM_CORES 3
    #undef HEIGHT
    #define HEIGHT IMHT/NUM_CORES   //the height of a chunk processed by the worker
#else   //small enough for 4 cores
    #undef NUM_CORES
    #define NUM_CORES 4
    #undef HEIGHT
    #define HEIGHT IMHT/NUM_CORES   //the height of a chunk processed by the worker
#endif
#endif

out port cledG = PORT_CLOCKLED_SELG;
out port cledR = PORT_CLOCKLED_SELR;

in port buttons = PORT_BUTTON;

const char infname[] = "test.pgm"; //put your input image path here, absolute path
const char outfname[] = "testout.pgm"; //put your output image path here, absolute path

/////////////////////////////////////////////////////////////////////////////////////////
//
// helper functions
//
/////////////////////////////////////////////////////////////////////////////////////////

/* function to return the mathematical definition of a mod b
 * (a%b only returns the remainder in C, so -1%5=-1 rather than
 * the desired value of 4)
 */
int mod(int a, int b)
{
    int r = a % b;
    return r < 0 ? r + b : r;
}

void print_img(uchar img[IMHT][IMWD]) {
    for(int y = 0; y < IMHT; y++) {
        for(int x = 0; x < IMWD; x++) {
            printf("-%4.1d ", img[y][x]);
        }
        printf("\n\n");
    }
}

void waitMoment(int duration) {
    timer tmr;
    uint waitTime;
    tmr :> waitTime;
    waitTime += duration;
    tmr when timerafter(waitTime) :> void;
}

/*
 * Function to return the 4 codes to be sent to the LED quadrants to display
 * a given binary number.
 *
 * The LED quads display the most significant digits of a
 * byte, e.g.:
 * 0b10000 gives pattern 001
 * 0b110000 gives pattern 011
 * 0b1110000 gives pattern 111
 * 0b1010000 gives pattern 101
 *
 * NOTE: with 12 bits the max number to display is 4095
 */
{uint, uint, uint, uint} getBinaryLightPattern(int decimal) {
    if(decimal > 4095) decimal = mod(decimal, 4095);  //max val permissible is 4095
    uchar binary[12] = {0}; //binary string
    uchar i = 0;
    while(decimal > 0)
    {
        binary[i] = decimal % 2;    //remainder is current bit
        decimal = decimal/2;        //now get rid of this bit
        i++;
    }

    uchar msf;
    uchar val = 0;
    uint pattern[4]; //holds each of the LED vals
    i = 0;
    for(int n = 0; n < 12; n+=3) {  //go through the binary in chunks of 3 bits
        val = 0;
        msf = 64;   //0b1000000 is most significant bit for LED code
        for(int m = 2; m >= 0; m--) {   //go through each of the 3 digits
            val += binary[n + m] * msf; //if the binary digit is on, the msf is added
            msf /= 2;   //msf is now decreased for the next column
        }
        pattern[i] = val;
        i++;
    }
    return {pattern[0], pattern[1], pattern[2], pattern[3]};
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Read Image from pgm file with path and name infname[] to channel c_out
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataInStream(const char infname[], chanend c_out) {
    int res;
    uchar running = 1;
    int mode = MODE_RUNNING;
    uchar line[IMWD];
    printf("DataInStream:Start...\n");
    while(running) {
        if(mode == MODE_RUNNING || mode == MODE_IDLE) {
            c_out :> mode;
            if(mode == MODE_HARVEST || mode == MODE_PAUSED) {
                mode = MODE_RUNNING;
            }
        } else if(mode == MODE_FARM) {
            res = _openinpgm(infname, IMWD, IMHT);
            if (res) {
                printf("DataInStream:Error openening %s\n.", infname);
                return;
            }

            for (int y = 0; y < IMHT; y++) {
                if(_readinline(line, IMWD) == -1) {
                    printf("Error reading in line!\n");
                    return;
                }
                for (int x = 0; x < IMWD; x++) {
                    c_out <: line[x];
                }
            }
            _closeinpgm();
            mode = MODE_RUNNING;
        } else if(mode == MODE_TERMINATE) {
            running = 0;
        }
    }
    printf("DataInStream:Done...\n");
    return;
}

void gameoflife(chanend farmer, int worker_id, chanend worker_below, chanend worker_above) {
    printf("GameOfLife:Start\n");
    int mode = MODE_IDLE;
    int aliveCount = 0;
    uchar running = 1;
    /*  array to hold the chunk of the image to work on, with an extra
     *  line above and below for the neighbours we'll read but won't write.
     *  Only worker 0 will use the extra capacity for the remained given by IMHT%NUM_CORES
     *  If IMWD doesnt divide by 8 then add an extra byte for the remainder, (the extra bits will be padding and equal 0)
     *  Use img[y][x] |= 1 << sh to set a bit, img[y][x] &= ~(1 << sh) to clear a bit.
     */
    uchar img[HEIGHT + IMHT%NUM_CORES + 2][IMWD/8 + (IMWD%8!=0?1:0)]={{0}};
    //3 lines used to read the neighbour values, (where they wont get
    //overwritten by the updating of the cells). The middle line at anytime is the line
    //to be updated.
    uchar buffer_img[2][IMWD/8 + (IMWD%8!=0?1:0)]={{0}};
    int h;  //the height of the chunk this worker is working on
    while(running) {
        if(mode == MODE_IDLE) {
            farmer :> mode;
        } else if(mode == MODE_PAUSED) {
            farmer :> mode;
        } else if(mode == MODE_FARM) {
            //read data in from farmer
            farmer :> h;    //read in the chunk height this worker is processing
            uchar val;
            int sh; //used to track how much to shift the byte by to get to the current cell
            for (int y = 0; y < h + 2; y++) {   //+2 to compensate for the extra read-only lines
                sh = 7;
                for (int x = 0; x < IMWD; x++) {
                    farmer :> val;
                    //worker0 will receive its top buffer line AFTER the rest of the chunk, so mod to put in the right place
                    int _y = y;
                    if(worker_id == 0) {
                        _y = mod(y+1, h+2);
                    }
                    if(val == ALIVE) {
                        img[_y][x/8] |= 1 << sh;
                    } else {
                        img[_y][x/8] &= ~(1 << sh);
                    }
                    if(sh == 0) {
                        sh = 7;
                    } else {
                        sh--;
                    }
                    //if we reach the end of the row, but havent gone throuhg the whole byte,
                    //then pad the rest of the bits by setting them to 0
                    if(x == IMWD - 1 && sh != 7) {
                        while(sh >= 0) {
                            img[_y][x/8] &= ~(1 << sh);
                            sh--;
                        }
                    }
                }
            }
            /*if(worker_id == 1) {
                for(int y = 0; y < h+2; y++) {
                    printf("y = %d\n", y);
                    for(int x = 0; x < IMWD/8 + (IMWD%8!=0?1:0); x++) {
                        for( int sh = 7; sh >= 0; sh --) {
                            printf("%d ", (img[y][x] >> sh) & 1);
                        }
                        printf("   ");
                    }
                    printf("\n");
                }
                printf("DONE\n\n");
            }*/
            mode = MODE_RUNNING;
        } else if(mode == MODE_HARVEST) {
            //send data back to farmer
            int sh = 7;
            for (int y = 1; y < h + 1; y++) {
                sh = 7;
                for (int x = 0; x < IMWD; x++) {
                    if(((img[y][x/8] >> sh) & 1) == 1) {
                        farmer <: (uchar)(ALIVE);
                    } else {
                        farmer <: (uchar)(DEAD);
                    }
                    if(sh == 0) {
                        sh = 7;
                    } else {
                        sh--;
                    }
                }
            }
            mode = MODE_RUNNING;
        }  else if(mode == MODE_TERMINATE) {
            running = 0;
        }  else if(mode == MODE_RUNNING) {
            farmer :> mode;
            farmer <: aliveCount;

            //reset alive count for next iteration
            aliveCount = 0;

            //copy first 3 rows into buffer_img
            for(int y = 0; y < 2; y++) {
                for(int x = 0; x < IMWD/8 + (IMWD%8!=0?1:0); x++) {
                    buffer_img[y][x] = img[y][x];
                }
            }

            //  *** PROCESS DATA ***
            uchar n_count = 0;
            for(int y = 1; y < h + 1; y++) {   //loop through only the parts of the image we'll write to
                for(int x = 0; x < IMWD/8 + (IMWD%8!=0?1:0); x++) {
                    for(int sh = 7; sh >= 0; sh --) {
                        for(int j = -1; j <= 1; j++) {
                            for(int i = -1; i <= 1; i++) {
                                if(i == 0 && j == 0) {  //dont count yourself!
                                    continue;
                                } else {
                                    int _x = x, _sh = sh;
                                    //check if we need to skip to the byte ahead or before
                                    if(sh - i < 0) {
                                        _x++;
                                    } else if(sh - i > 7) {
                                        _x--;
                                    }
                                    if(j != 1) {
                                        if(((buffer_img[1+j][mod(_x, IMWD/8 + (IMWD%8!=0?1:0))] >> mod(sh - i, 8)) & 1) == 1) {
                                            n_count++;
                                        }
                                    } else {
                                        if(((img[y + 1][mod(_x, IMWD/8 + (IMWD%8!=0?1:0))] >> mod(sh - i, 8)) & 1) == 1) {
                                            n_count++;
                                        }
                                    }
                                }
                            }
                        }

                        //apply GoL rules
                        if(((buffer_img[1][x] >> sh) & 1) == 1) {
                            aliveCount++;
                            if(n_count < 2) {
                                img[y][x] &= ~(1 << sh);
                            } else if(n_count == 2 || n_count == 3) {
                                img[y][x] |= 1 << sh;
                            } else if(n_count > 3) {
                                img[y][x] &= ~(1 << sh);
                            }
                        } else {
                            if(n_count == 3) {
                                img[y][x] |= 1 << sh;
                            } else {
                                img[y][x] &= ~(1 << sh);
                            }
                        }
                        n_count = 0;
                    }
                }
                //shift the buffer down
                if(y != h ) {
                    memcpy(buffer_img[0], buffer_img[1], sizeof(buffer_img[0]));
                    memcpy(buffer_img[1], img[y + 1], sizeof(buffer_img[1]));
                }
            }

            /*    **** communicate changes in overlapping rows to the appropriate threads****
             *
             *    *** EVEN id workers ***
             *    send my bottom *calculated* row to worker below
             *    receive my bottom *neighbour* row from worker below
             *    receive my top *neighbour* row from worker above
             *    send my top *calculated* row to worker above
             *    *** ODD id workers ***
             *    receive my top *neighbour* row from worker above
             *    send my top *calculated* row to worker above
             *    send my bottom *calculated* row to worker below
             *    receive my bottom *neighbour* row from worker below
             */
            uchar val;
            if(worker_id % 2 == 0) {
                for(int x = 0; x < IMWD/8 + (IMWD%8!=0?1:0); x++) {
                    for(int sh = 7; sh >= 0; sh --) {
                        if(((img[h][x] >> sh) & 1) == 1) {
                            worker_below <: (uchar)(ALIVE);
                        } else {
                            worker_below <: (uchar)(DEAD);
                        }
                        worker_below :> val;
                        if(val == ALIVE) {
                            img[h+1][x] |= 1 << sh;
                        } else {
                            img[h+1][x] &= ~(1 << sh);
                        }
                        worker_above :> val;
                        if(val == ALIVE) {
                            img[0][x] |= 1 << sh;
                        } else {
                            img[0][x] &= ~(1 << sh);
                        }
                        if(((img[1][x] >> sh) & 1) == 1) {
                            worker_above <: (uchar)(ALIVE);
                        } else {
                            worker_above <: (uchar)(DEAD);
                        }
                    }
                }
            } else {    //odd id workers
                for(int x = 0; x < IMWD/8 + (IMWD%8!=0?1:0); x++) {
                    for(int sh = 7; sh >= 0; sh --) {
                        worker_above :> val;
                        if(val == ALIVE) {
                           img[0][x] |= 1 << sh;
                        } else {
                           img[0][x] &= ~(1 << sh);
                        }
                        if(((img[1][x] >> sh) & 1) == 1) {
                            worker_above <: (uchar)(ALIVE);
                        } else {
                            worker_above <: (uchar)(DEAD);
                        }
                        if(((img[h][x] >> sh) & 1) == 1) {
                            worker_below <: (uchar)(ALIVE);
                        } else {
                            worker_below <: (uchar)(DEAD);
                        }
                        worker_below :> val;
                        if(val == ALIVE) {
                           img[h+1][x] |= 1 << sh;
                        } else {
                           img[h+1][x] &= ~(1 << sh);
                        }
                    }
                }
            }
        }
    }
    printf( "GameOfLife:Done...\n" );
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// The farmer.
//
/////////////////////////////////////////////////////////////////////////////////////////
void distributor(chanend c_in, chanend c_out, chanend workers[NUM_CORES], chanend c_buttons, chanend c_visualiser) {
    printf("Processing with %d cores.\n", NUM_CORES);
    uchar val;
    uint t1, t2;
    uint td;
    unsigned long tt1 = 0;
    unsigned long tt2 = 0;
    uchar running = 1;
    int buttonPress;
    int mode = MODE_IDLE;
    int aliveCount = 0; //total no. of alive cells
    int gen = 0;    //the current generation
    int heights[NUM_CORES]; //array to store the heights of the chunks to be processed by the workers
    heights[0] = HEIGHT + IMHT%NUM_CORES;   //the first worker takes any extra work (remainder) that doesnt divide by the num of workers
    for(int i = 1; i < NUM_CORES; i++) {    //each of the other heights are as normal
        heights[i] = HEIGHT;
    }
    printf("ProcessImage:Start, size = %dx%d\n", IMHT, IMWD);
    while(running) {
        if(mode == MODE_IDLE) {
            c_buttons :> buttonPress;
            if(buttonPress == BUTTON_A) {
                mode = MODE_FARM;
            } else if(buttonPress == BUTTON_D) {
                mode = MODE_TERMINATE;
            }
            for(int i = 0; i < NUM_CORES; i++) {
                workers[i] <: mode;
            }
            c_visualiser <: mode;
            c_in <: mode;
            c_out <: mode;
        } else if(mode == MODE_RUNNING) {
            timer _timer;
            if(gen == 0) {
                _timer :> t1;
            } else if(gen%10 == 0 && gen <= 50) {
                _timer :> t2;
                tt1 += t2 - t1;
                td = t2 - t1;
                t1 = t2;
            } else if(gen%10 == 0 && gen > 50 && gen != 100) {
               _timer :> t2;
               tt2 += t2 - t1;
               td = t2 - t1;
               t1 = t2;
            } else if(gen == 100) {
                _timer :> t2;
                tt2 += t2 - t1;
                td = t2 - t1;
                mode = MODE_HARVEST;
                //100000 timer ticks = 1ms
                printf("%d generations in %u + %u ticks\n", gen, tt1, tt2);
            }
            aliveCount = 0; //init number of alive cells
            c_buttons :> buttonPress;
            if(buttonPress == BUTTON_A) {
                mode = MODE_FARM;
            } else if(buttonPress == BUTTON_C) {
                mode = MODE_HARVEST;
            } else if(buttonPress == BUTTON_B) {
                mode = MODE_PAUSED;
            } else if(buttonPress == BUTTON_D) {
                mode = MODE_TERMINATE;
            }
            //update the workers on the current mode and get the number of alive cells in each
            int alive;
            for(int n = 0; n < NUM_CORES; n++) {
                workers[n] <: mode;
                workers[n] :> alive;
                aliveCount += alive;
            }
            gen++;  //inc generation count
            c_visualiser <: mode;
            c_visualiser <: aliveCount; //tell vis the total no. of alive cells
            c_in <: mode;
            c_out <: mode;
        } else if(mode == MODE_PAUSED) {
            c_buttons :> buttonPress;
            c_visualiser <: mode;
            c_visualiser <: gen;    //tell vis which gen we are on to display it
            if(buttonPress == BUTTON_B) {
                mode = MODE_RUNNING;
                for(int i = 0; i < NUM_CORES; i++) {
                    workers[i] <: mode;
                }
                c_visualiser <: mode;
                c_visualiser <: gen;
                c_in <: mode;
                c_out <: mode;
            } else if(buttonPress == BUTTON_D) {
                mode = MODE_TERMINATE;
                for(int i = 0; i < NUM_CORES; i++) {
                    workers[i] <: mode;
                }
                c_visualiser <: mode;
                c_visualiser <: gen;
                c_in <: mode;
                c_out <: mode;
            }
        } else if(mode == MODE_FARM) {
            printf("FARM\n");
            int cumulative_heights[NUM_CORES];  //stores the indices of the boundaries
            //set these boundaries:
            cumulative_heights[0] = heights[0];
            for(int i = 1; i < NUM_CORES; i++) {
                cumulative_heights[i] = cumulative_heights[i-1] + heights[i];
            }
            //tell the workers the size of the chunk they are processing
            for(int i = 0; i < NUM_CORES; i++) {
                workers[i] <: heights[i];
            }
            //Farm out the work
            for (int y = 0; y < IMHT; y++) {
                printf("y = %d\n", y);
                for(int x = 0; x < IMWD; x++) {
                    c_in :> val; //read in the cell value
                    //decide which workers to send this to based on whether it is between the correct boundaries.
                    //Note the preprocessing directives used to compile the correct code for the number of workers in use.
                    if(y == IMHT - 1 || (y >= 0 && y <= cumulative_heights[0])) {
                        workers[0] <: val;
                    }
                    if(y >= cumulative_heights[0] - 1 && y <= cumulative_heights[1]) {
                        workers[1] <: val;
                    }
#if(NUM_CORES == 3)
                    if(y == 0 ||(y >= cumulative_heights[1] - 1 && y <= cumulative_heights[2] - 1)) {
                        workers[2] <: val;
                    }
#elif(NUM_CORES == 4)
                    if(y >= cumulative_heights[1] - 1 && y <= cumulative_heights[2]) {
                        workers[2] <: val;
                    }
                    if(y == 0 ||(y >= cumulative_heights[2] - 1 && y <= cumulative_heights[3] - 1)) {
                        workers[3] <: val;
                    }
#endif
                }
            }
            printf("FARM COMPLETE\n");
            mode = MODE_RUNNING;
            c_visualiser <: mode;   //update vis to running (otherwise stuck in idle/farm/harvest)
        } else if(mode == MODE_HARVEST) {
            printf("HARVEST\n");
            //harvest and output data from each worker
            for(uchar i = 0; i < NUM_CORES; i++) {
                for (int y = 0; y < heights[i]; y++) {
                    for (int x = 0; x < IMWD; x++) {
                        workers[i] :> val;
                        c_out <: val;
                    }
                }
            }
            printf("HARVEST COMPLETE\n");
            mode = MODE_RUNNING;
            c_visualiser <: mode;   //update vis to running (otherwise stuck in idle/farm/harvest)
        } else if(mode == MODE_TERMINATE) {
            running = 0;
        }
    }
    printf( "Distributor:Done...\n" );
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Write pixel stream from channel c_in to pgm image file
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataOutStream(const char outfname[], chanend c_in) {
    int res;
    int mode = MODE_RUNNING;
    uchar line[IMWD];
    uchar running = 1;
    printf("DataOutStream:Start...\n");
    while(running) {
        if(mode == MODE_RUNNING || mode == MODE_IDLE) {
            c_in :> mode;
            if(mode == MODE_FARM || mode == MODE_PAUSED) {
                mode = MODE_RUNNING;
            }
        } else if(mode == MODE_HARVEST) {
            res = _openoutpgm(outfname, IMWD, IMHT);
            if (res) {
                printf("DataOutStream:Error opening %s\n.", outfname);
                return;
            }

            for (int y = 0; y < IMHT; y++) {
                for (int x = 0; x < IMWD; x++) {
                    c_in :> line[x];
                }
                _writeoutline(line, IMWD);
            }

            _closeoutpgm();
            mode = MODE_RUNNING;
        } else if(mode == MODE_TERMINATE) {
            running = 0;
        }
    }
    printf( "DataOutStream:Done...\n" );
    return;
}

void buttonListener(in port b, chanend farmer) {
    int r;
    uchar running = 1;
    //var to prevent buttons from rapid firing when held down
    int isReleased = 1;

    //continuously read button state and send them to user (even if nothing is pressed)
    //(This prevents the user from hanging up until a button is actually pressed)
    while (running) {
        b :> r; //read button

        //if no buttons are pressed then all are released so reset flag
        if(r == BUTTON_NONE) {
            isReleased = 1;
        } else {
            if(isReleased == 0) {   //this is not the first time they were pressed
                r = BUTTON_NONE;    //set r to none to prevent rapid fire of buttons
            }
            isReleased = 0; //they were pressed so released is now false
        }
        farmer <: r; // send button pattern to farmer
        if(r == BUTTON_D) {
            running = 0;
        }
        waitMoment(500000); //pause to let user release button
    }
    printf("Buttons terminated. Goodbye!\n");
}

//DISPLAYS an LED pattern in one quadrant of the clock LEDs
int showLED(out port p, chanend visualiser) {
    uint lightUpPattern;
    uchar running = 1;
    while (running) {
        visualiser :> lightUpPattern; //read LED pattern from visualiser process
        if(lightUpPattern == TERMINATE) {
            running = 0;
        } else {
            p <: lightUpPattern; //send pattern to LEDs
        }
    }
    printf("LED terminated. goodbye\n");
    return 0;
}

//thread to control LED display
void visualiser(chanend farmer, chanend quadrants[4]) {
    cledG <: 1; //make lights green
    cledR <: 0;
    uchar running = 1;
    int aliveCount; //total num of alive cells
    int gen = 0;    //current generation
    int mode = MODE_IDLE;
    while (running) {
        if(mode == MODE_IDLE || mode == MODE_FARM || mode == MODE_HARVEST) {
            cledR <: 1;
            cledG <: 0;
            quadrants[0] <: 112;
            quadrants[1] <: 112;
            quadrants[2] <: 112;
            quadrants[3] <: 112;
            farmer :> mode;
        } else if(mode == MODE_RUNNING) {   /***display the number of alive cells***/
            cledG <: 1;
            cledR <: 0;
            farmer :> mode;
            farmer :> aliveCount;
            //score the num of alive cells in range 0-12 using
            // f(x)=-(x+1/12)^(-1) + 13
            int score = (int)(pow((-((float)(aliveCount)/(float)(CELLCOUNT))+1/12), -1) + 13);
            if(score > 12) score = 12;  //safety check
            if(score < 0) score = 0;  //safety check
            //printf("frac = %f, score = %d\n", (float)(aliveCount)/(float)(CELLCOUNT), score);
            int quad = (score-1)/3; //the quadrant the score is in
            int rem = score%3;
            uint pattern;
            if(score == 0) pattern = 16;
            else if(rem == 1) pattern = 16;  //light pattern 001
            else if(rem == 2) pattern = 48; //light pattern 011
            else if(rem == 0) pattern = 112; //light pattern 111
            //light up all quads before the one with the score in, and display the
            //correct light pattern on that last one. All others afterwards must be off.
            if(quad == 0) {
                quadrants[0] <: pattern;
                quadrants[1] <: 0;
                quadrants[2] <: 0;
                quadrants[3] <: 0;
            } else if(quad == 1) {
                quadrants[0] <: 112;
                quadrants[1] <: pattern;
                quadrants[2] <: 0;
                quadrants[3] <: 0;
            } else if(quad == 2) {
                quadrants[0] <: 112;
                quadrants[1] <: 112;
                quadrants[2] <: pattern;
                quadrants[3] <: 0;
            } else if(quad == 3) {
                quadrants[0] <: 112;
                quadrants[1] <: 112;
                quadrants[2] <: 112;
                quadrants[3] <: pattern;
            }
        } else if(mode == MODE_PAUSED) {    /***display the current generation (in binary)***/
            cledG <: 0;
            cledR <: 1;
            farmer :> mode;
            farmer :> gen;
            uint pattern[4];
            {pattern[0], pattern[1], pattern[2], pattern[3]} = getBinaryLightPattern(gen);
            for(uchar n = 0; n < 4; n++) {
                quadrants[n] <: pattern[n];
            }
            printf("Generation no. = %d\n", gen);
        } else if(mode == MODE_TERMINATE) {
            running = 0;
            cledR <: 1;
            cledG <: 0;
            quadrants[0] <: 112;
            quadrants[1] <: 112;
            quadrants[2] <: 112;
            quadrants[3] <: 112;
            waitMoment(10000000);
            quadrants[0] <: TERMINATE;
            quadrants[1] <: TERMINATE;
            quadrants[2] <: TERMINATE;
            quadrants[3] <: TERMINATE;
        }
    }
    printf("Visualiser terminated. goodbye\n");
}

//MAIN PROCESS defining channels, orchestrating and starting the threads
//TODO: -implement more threads per core and compare speed advantages. see the bottom of: https://www.xmos.com/published/xc-concurrency
//      -fix button lag
//      -implement fast neighbour count
int main() {
#ifdef INPUT_TOO_LARGE
    printf("The input image is too large to be processed!\n");
    return 1;
#elif NUM_CORES == 3
    //channels to read and write the image, talk to buttons and the visualiser
    chan c_inIO, c_outIO, c_buttons, c_visualiser;
    //chans between the distributor and workers, the light quads, and for workers to communicate between each other
    chan workers[NUM_CORES], quadrants[4], c[NUM_CORES];
    par
    {
        on stdcore[0] : buttonListener(buttons, c_buttons);
        on stdcore[0] : DataInStream( infname, c_inIO );
        on stdcore[0] : distributor( c_inIO, c_outIO, workers, c_buttons, c_visualiser);
        on stdcore[1] : DataOutStream( outfname, c_outIO );

        on stdcore[0] : visualiser(c_visualiser, quadrants);
        on stdcore[0] : showLED(cled0, quadrants[0]);
        on stdcore[1] : showLED(cled1, quadrants[1]);
        on stdcore[2] : showLED(cled2, quadrants[2]);
        on stdcore[3] : showLED(cled3, quadrants[3]);

        on stdcore[1] : gameoflife( workers[0], 0, c[0], c[2] );
        on stdcore[2] : gameoflife( workers[1], 1, c[1], c[0] );
        on stdcore[3] : gameoflife( workers[2], 2, c[2], c[1] );
    }
    return 0;
#elif NUM_CORES == 4
    //channels to read and write the image, talk to buttons and the visualiser
    chan c_inIO, c_outIO, c_buttons, c_visualiser;
    //chans between the distributor and workers, the light quads, and for workers to communicate between each other
    chan workers[NUM_CORES], quadrants[4], c[NUM_CORES];
    par
    {
        on stdcore[0] : buttonListener(buttons, c_buttons);
        on stdcore[1] : DataInStream( infname, c_inIO );
        on stdcore[2] : distributor( c_inIO, c_outIO, workers, c_buttons, c_visualiser);
        on stdcore[3] : DataOutStream( outfname, c_outIO );

        on stdcore[0] : visualiser(c_visualiser, quadrants);
        on stdcore[0] : showLED(cled0, quadrants[0]);
        on stdcore[1] : showLED(cled1, quadrants[1]);
        on stdcore[2] : showLED(cled2, quadrants[2]);
        on stdcore[3] : showLED(cled3, quadrants[3]);

        on stdcore[0] : gameoflife( workers[0], 0, c[0], c[3] );
        on stdcore[1] : gameoflife( workers[1], 1, c[1], c[0] );
        on stdcore[2] : gameoflife( workers[2], 2, c[2], c[1] );
        on stdcore[3] : gameoflife( workers[3], 3, c[3], c[2] );
    }
    return 0;
#else
    printf("%d is an unreasonable number of cores! Can use 3 or 4 cores.\n", NUM_CORES);
    return 1;
#endif
}
