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
#include "pgmIO.h"

/*  BY TRIAL AND ERROR, ~7920 bytes seems to be the most that
 *  you can handle per core i.e. in img[Height+2][IMWD] where
 *  e.g. IMWD = 120, HEIGHT = 64
 */
#define MAX_BYTES 6900  //val above this causes fopen error; perror() gives ENOMEM "Not enough space"
#define IMHT (128-128%4) //img height. Must be a multiple of 4 to allow equal farming of image
#define IMWD 128 //img width
#if IMWD*(IMHT/4) <= MAX_BYTES
    #define HEIGHT IMHT/4
#else
    #define HEIGHT IMHT/4 //MAX_BYTES/IMWD
#endif

//#define HEIGHT 32    //height of worker chunk
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

out port cled0 = PORT_CLOCKLED_0;
out port cled1 = PORT_CLOCKLED_1;
out port cled2 = PORT_CLOCKLED_2;
out port cled3 = PORT_CLOCKLED_3;
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
{int, int, int, int} getBinaryLightPattern(int decimal) {
    if(decimal > 4095) decimal = mod(decimal, 4095);  //max val permissible is 4095
    uchar binary[12] = {0}; //binary string
    int i = 0;
    while(decimal > 0)
    {
        binary[i] = decimal % 2;    //remainder is current bit
        decimal = decimal/2;        //now get rid of this bit
        i++;
    }

    int msf;
    int val = 0;
    int pattern[4]; //holds each of the LED vals
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
    printf("HEIGHT = %d\n", HEIGHT);
    int res;
    int running = 1;
    int mode = MODE_RUNNING;
    uchar line[IMWD];  //array to store the whole image
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

            /*
             * Loop through a worker chunk of the image, accomodating for an extra line above
             * and below to store the neighbours which that worker will not modify.
             * Do this for each of the 4 workers.
             *
             * n * HEIGHT - 1   gets you to the line behind the one the worker will be accessing.
             * + y              gets you to the current row
             */
            for (int y = 0; y < IMHT; y++) {
                _readinline(line, IMWD);
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

//TODO: implement a cache for the neighbours rather than reading in the whole img before processing
void gameoflife(chanend farmer, int worker_id, chanend worker_below, chanend worker_above) {
    printf("GameOfLife:Start\n");
    int mode = MODE_IDLE;
    int aliveCount = 0;
    int running = 1;
    //arrays to hold the chunk of the image to work on, with an extra
    //line above and below for the neighbours we'll read but won't write
    uchar img[HEIGHT + 2][IMWD];
    uchar buffer_img[3][IMWD];

    while(running) {
        if(mode == MODE_IDLE) {
            farmer :> mode;
        } else if(mode == MODE_PAUSED) {
            farmer :> mode;
        } else if(mode == MODE_FARM) {
            //printf("GoL FARM\n");
            //read data in from farmer
            for (int y = 0; y < HEIGHT + 2; y++) {
                for (int x = 0; x < IMWD; x++) {
                    if(worker_id == 0) {
                        farmer :> img[mod(y+1, HEIGHT + 2)][x];
                    } else {
                        farmer :> img[y][x];
                    }
                }
            }
            mode = MODE_RUNNING;
        } else if(mode == MODE_HARVEST) {
            //send data back
            for (int y = 1; y < HEIGHT + 1; y++) {
                for (int x = 0; x < IMWD; x++) {
                    farmer <: img[y][x];
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
            for(int y = 0; y < 3; y++) {
                for(int x = 0; x < IMWD; x++) {
                    buffer_img[y][x] = img[y][x];
                }
            }

            //  *** PROCESS DATA ***
            int n_count = 0;
            for(int y = 1; y < HEIGHT + 1; y++) {   //loop through only the parts of the image we'll write to
                for(int x = 0; x < IMWD; x++) {
                    for(int j = -1; j <= 1; j++) {  //loop through the neighbours
                        for(int i = -1; i <= 1; i++) {
                            if(i==0 && j==0) {  //careful not to count yourself as a neighbour!
                                continue;
                            } else {
                                if(buffer_img[mod(1 + j, IMHT)][mod(x+i, IMWD)] == ALIVE) {  //count the neighbours
                                    n_count++;
                                }
                            }
                        }
                    }
                    //implement game of life rules
                    if(buffer_img[1][x] == ALIVE) {
                        aliveCount++;
                        if(n_count < 2) {
                            img[y][x] = DEAD;
                        } else if(n_count == 2 || n_count == 3) {
                            img[y][x] = ALIVE;
                        } else if(n_count > 3) {
                            img[y][x] = DEAD;
                        }
                    } else {
                        if(n_count == 3) {
                            img[y][x] = ALIVE;
                        } else {
                            img[y][x] = DEAD;
                        }
                    }
                    n_count = 0;    //reset neighbour count for next cell
                }
                if(y != HEIGHT) {
                    memcpy(buffer_img[0], buffer_img[1], sizeof(buffer_img[0]));
                    memcpy(buffer_img[1], buffer_img[2], sizeof(buffer_img[1]));
                    memcpy(buffer_img[2], img[y+2], sizeof(buffer_img[2]));
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
            if(worker_id % 2 == 0) {
                for(int x = 0; x < IMWD; x++) {
                    worker_below <: img[HEIGHT][x];
                    worker_below :> img[HEIGHT + 1][x];
                    worker_above :> img[0][x];
                    worker_above <: img[1][x];
                }
            } else {    //odd id workers
                for(int x = 0; x < IMWD; x++) {
                    worker_above :> img[0][x];
                    worker_above <: img[1][x];
                    worker_below <: img[HEIGHT][x];
                    worker_below :> img[HEIGHT + 1][x];
                }
            }
        }
    }
    printf( "GameOfLife:Done...\n" );
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Start your implementation by changing this function to farm out parts of the image...
//
/////////////////////////////////////////////////////////////////////////////////////////
void distributor(chanend c_in, chanend c_out, chanend workers[4], chanend c_buttons, chanend c_visualiser) {//chanend worker0, chanend worker1, chanend worker2, chanend worker3, chanend c_buttons) {
    uchar val;
    int running = 1;
    int buttonPress;
    int mode = MODE_IDLE;
    int aliveCount = 0; //total no. of alive cells
    int gen = 0;    //the current generation
    printf("ProcessImage:Start, size = %dx%d\n", IMHT, IMWD);
    while(running) {
        if(mode == MODE_IDLE) {
            //printf("MODE IDLE\n");
            c_buttons :> buttonPress;
            if(buttonPress == BUTTON_A) {
                mode = MODE_FARM;
            } else if(buttonPress == BUTTON_D) {
                mode = MODE_TERMINATE;
            }
            workers[0] <: mode;
            workers[1] <: mode;
            workers[2] <: mode;
            workers[3] <: mode;
            c_visualiser <: mode;
            c_in <: mode;
            c_out <: mode;
        } else if(mode == MODE_RUNNING) {
            //printf("RUNNING\n");
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
            for(int n = 0; n < 4; n++) {
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
            //printf("PAUSED\n");
            c_buttons :> buttonPress;
            c_visualiser <: mode;
            c_visualiser <: gen;    //tell vis which gen we are on to display it
            if(buttonPress == BUTTON_B) {
                mode = MODE_RUNNING;
                workers[0] <: mode;
                workers[1] <: mode;
                workers[2] <: mode;
                workers[3] <: mode;
                c_visualiser <: mode;
                c_visualiser <: gen;
                c_in <: mode;
                c_out <: mode;
            } else if(buttonPress == BUTTON_D) {
                mode = MODE_TERMINATE;
                workers[0] <: mode;
                workers[1] <: mode;
                workers[2] <: mode;
                workers[3] <: mode;
                c_visualiser <: mode;
                c_visualiser <: gen;
                c_in <: mode;
                c_out <: mode;
            }
        } else if(mode == MODE_FARM) {
            printf("FARM\n");
            //Farm out the work
            int m;
            for (int y = 0; y < IMHT; y++) {
                m = mod(y, HEIGHT);
                //printf("sending to worker %d\n", y/HEIGHT);
                for (int x = 0; x < IMWD; x++) {
                    c_in :> val;
                    if(m == 0) {
                        //printf("AS WELL AS, sending to worker %d\n", mod(3 + y/HEIGHT, 4));
                        workers[mod(3 + y/(int)(HEIGHT), 4)] <: val;
                    } else if(m == HEIGHT - 1) {
                        //printf("AS WELL AS, sending to worker %d\n", mod(1 + y/HEIGHT, 4));
                        workers[mod(1 + y/(int)(HEIGHT), 4)] <: val;
                    }
                    workers[y/(int)(HEIGHT)] <: val;
                }
                //printf("y = %d\n", y);
            }
            printf("FARM COMPLETE\n");
            mode = MODE_RUNNING;
            c_visualiser <: mode;   //update vis to running (otherwise stuck in idle/farm/harvest)
        } else if(mode == MODE_HARVEST) {
            printf("HARVEST\n");
            //harvest and output data
            for (int y = 0; y < IMHT; y++) {
                for (int x = 0; x < IMWD; x++) {
                    workers[y/(int)(HEIGHT)] :> val;
                    c_out <: val;
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
    int running = 1;
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
            /*
             * Loop through a worker chunk of the image, accomodating for an extra line above
             * and below to store the neighbours which that worker will not modify.
             * Do this for each of the 4 workers.
             *
             * n * HEIGHT - 1   gets you to the line behind the one the worker will be accessing.
             * + y              gets you to the current row
             */
            for (int y = 0; y < IMHT; y++) {
                for (int x = 0; x < IMWD; x++) {
                    c_in :> line[x];
                    //printf("-%4.1d ", line[x]);
                }
                _writeoutline(line, IMWD);
                //printf("\n");
            }

            //print_img(img); //print the image to stdout for easy viewing
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
    int running = 1;
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
        farmer <: r; // send button pattern to userAnt
        if(r == BUTTON_D) {
            running = 0;
        }
        waitMoment(10000000); //pause to let user release button
    }
    printf("Buttons terminated. Goodbye!\n");
}

//DISPLAYS an LED pattern in one quadrant of the clock LEDs
int showLED(out port p, chanend visualiser) {
    unsigned int lightUpPattern;
    int running = 1;
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
    int running = 1;
    int aliveCount; //total num of alive cells
    int gen;    //current generation
    int mode = MODE_IDLE;
    while (running) {
        if(mode == MODE_IDLE || mode == MODE_FARM || mode == MODE_HARVEST) {
            //printf("VIS IDLE/FARM/HARVEST %d\n", mode);
            farmer :> mode;
        } else if(mode == MODE_RUNNING) {   /***display the number of alive cells***/
            farmer :> mode;
            farmer :> aliveCount;
            //score the num of alive cells in range 0-12
            int score = (int)(12*(float)(aliveCount)/(int)(0.5 * CELLCOUNT));   //play with this 0.5 heuristic to alter sensitivity
            if(score > 12) score = 12;  //safety check (incase you mess with the heuristic)
            int quad = (score-1)/3; //the quadrant the score is in
            int rem = score%3;
            int pattern;
            if(rem == 1) pattern = 16;  //light pattern 001
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
            farmer :> mode;
            farmer :> gen;
            int pattern[4];
            {pattern[0], pattern[1], pattern[2], pattern[3]} = getBinaryLightPattern(gen);
            for(int n = 0; n < 4; n++) {
                quadrants[n] <: pattern[n];
            }
            printf("Generation no. = %d\n", gen);
        } else if(mode == MODE_TERMINATE) {
            running = 0;
            quadrants[0] <: TERMINATE;
            quadrants[1] <: TERMINATE;
            quadrants[2] <: TERMINATE;
            quadrants[3] <: TERMINATE;
        }
    }
    printf("Visualiser terminated. goodbye\n");
}

//MAIN PROCESS defining channels, orchestrating and starting the threads
//TODO: add constraints on when buttons cause state change
//      fix testout.pgm premature end of file
int main() {
    chan c_inIO, c_outIO;   //channels to read and write the image
    chan workers[4], quadrants[4];
    chan c_01, c_12, c_23, c_30;
    chan c_buttons, c_visualiser;
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

        on stdcore[0] : gameoflife( workers[0], 0, c_01, c_30 );
        on stdcore[1] : gameoflife( workers[1], 1, c_12, c_01 );
        on stdcore[2] : gameoflife( workers[2], 2, c_23, c_12 );
        on stdcore[3] : gameoflife( workers[3], 3, c_30, c_23 );
    }
    //printf("Main:Done...\n");
    return 0;
}
