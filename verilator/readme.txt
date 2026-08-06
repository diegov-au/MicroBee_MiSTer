verilator prerequisites
-----------------------

Latest Verilator built from source

sudo apt-get install git perl python3 make autoconf g++ flex bison ccache
sudo apt-get install libgoogle-perftools-dev numactl perl-doc
sudo apt-get install zlibc zlib1g zlib1g-dev liblz4-dev
sudo apt install libsdl2-dev


cd verilator
make

obj_dir/Vemu