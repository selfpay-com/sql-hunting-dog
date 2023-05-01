# README #

Addin works only in MS SSMS 18 (2019)


Developed in Visual Studio 2019

## Install

[Download the latest release.](https://github.com/selfpay-com/sql-hunting-dog/releases)

You may need to unblock the zip file before extracting. Right click on the zip file in Windows Explorer and select Properties. 
If you see an `Unblock` button or checkbox then click it. 

Extract the zip file and copy the folder into the SSMS extension folder (`C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\Extensions\HuntingDog.19`). Remove or replace any previous version.
Run the included reg file to skip the load error.

## Building

Requires VS 2019 to build. VS 2022 does not build the sln since the SSMS shell is 32 bit and VS2022 is 64bit.



