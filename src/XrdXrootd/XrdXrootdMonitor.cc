/******************************************************************************/
/*                                                                            */
/*                   X r d X r o o t d M o n i t o r . c c                    */
/*                                                                            */
/* (c) 2004 by the Board of Trustees of the Leland Stanford, Jr., University  */
/*                            All Rights Reserved                             */
/*   Produced by Andrew Hanushevsky for Stanford University under contract    */
/*              DE-AC03-76-SFO0515 with the Department of Energy              */
/******************************************************************************/
  
//       $Id$

const char *XrdXrootdMonitorCVSID = "$Id$";

#include <errno.h>
#include <malloc.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>

#include "XrdOuc/XrdOucError.hh"
#include "XrdOuc/XrdOucLink.hh"
#include "XrdOuc/XrdOucNetwork.hh"
#include "XrdOuc/XrdOucPlatform.hh"

#include "Xrd/XrdScheduler.hh"
#include "XrdXrootd/XrdXrootdMonitor.hh"
#include "XrdXrootd/XrdXrootdTrace.hh"

/******************************************************************************/
/*                     S t a t i c   A l l o c a t i o n                      */
/******************************************************************************/
  
XrdScheduler      *XrdXrootdMonitor::Sched      = 0;
XrdOucError       *XrdXrootdMonitor::eDest      = 0;
XrdOucLink        *XrdXrootdMonitor::monDest    = 0;
XrdOucMutex        XrdXrootdMonitor::windowMutex;
kXR_int32          XrdXrootdMonitor::startTime  = 0;
int                XrdXrootdMonitor::monBlen    = 0;
int                XrdXrootdMonitor::lastEnt    = 0;
int                XrdXrootdMonitor::isEnabled  = 0;
int                XrdXrootdMonitor::numMonitor = 0;
kXR_int32          XrdXrootdMonitor::currWindow = 0;
kXR_int32          XrdXrootdMonitor::sizeWindow = 0;

/******************************************************************************/
/*                               G l o b a l s                                */
/******************************************************************************/
  
extern          XrdOucTrace       *XrdXrootdTrace;

/******************************************************************************/
/*                         L o c a l   C l a s s e s                          */
/******************************************************************************/

class XrdXrootdMonitor_Tick : public XrdJob
{
public:

void          DoIt() {
#ifndef NODEBUG
                      const char *TraceID = "MonTick";
#endif
                      time_t Now = XrdXrootdMonitor::Tick();
                      if (Window && Now)
                         Sched->Schedule((XrdJob *)this, Now+Window);
                         else {TRACE(DEBUG, "Monitor clock stopping.");}
                     }

void          Set(XrdScheduler *sp, int intvl) {Sched = sp; Window = intvl;}

      XrdXrootdMonitor_Tick() : XrdJob("monitor window clock")
                                  {Sched = 0; Window = 0;}
     ~XrdXrootdMonitor_Tick() {}

private:
XrdScheduler  *Sched;     // System scheduler
int            Window;
};

/******************************************************************************/
/*                           C o n s t r u c t o r                            */
/******************************************************************************/
  
XrdXrootdMonitor::XrdXrootdMonitor()
{
   kXR_int32 localWindow;

// Initialize the local window
//
   windowMutex.Lock();
   localWindow = currWindow;
   windowMutex.UnLock();

// Allocate a monitor buffer
//
   if (!(monBuff = (XrdXrootdMonBuff *)memalign(getpagesize(), monBlen)))
      eDest->Emsg("Monitor", "Unable to allocate monitor buffer.");
      else {nextEnt = 1;
            monBuff->info[0].offset.id[0] = 
                     static_cast<kXR_char>(XROOTD_MON_WINDOW);
            monBuff->info[0].arg1.Window  =
            monBuff->info[0].arg2.Window  = 
                     static_cast<kXR_int32>(ntohl(localWindow));
           }
}

/******************************************************************************/
/*                            D e s t r u c t o r                             */
/******************************************************************************/

XrdXrootdMonitor::~XrdXrootdMonitor()
{
// Release buffer
   if (monBuff) {Flush(); free(monBuff);}

// Decrease number being monitored if in selective mode
//
   if (isEnabled < 0)
      {windowMutex.Lock();
       numMonitor--;
       windowMutex.UnLock();
      }
}

/******************************************************************************/
/*                                 A l l o c                                  */
/******************************************************************************/
  
XrdXrootdMonitor *XrdXrootdMonitor::Alloc(int force)
{
   static XrdXrootdMonitor_Tick MonTick;
          XrdXrootdMonitor *mp;
          time_t Now;
          int lastVal;

// If enabled, create a new object (if possible)
//
   if (!isEnabled || (isEnabled < 0 && !force)) mp = 0;
      else if ((mp = new XrdXrootdMonitor()))
              if (!(mp->monBuff)) {delete mp; mp = 0;}

// Check if we should turn on the monitor clock
//
   if (mp && isEnabled < 0)
      {windowMutex.Lock();
       lastVal = numMonitor; numMonitor++;
       if (!lastVal)
          {Now = time(0);
           currWindow = static_cast<kXR_int32>(Now);
           MonTick.Set(Sched, sizeWindow);
           Sched->Schedule((XrdJob *)&MonTick, Now+sizeWindow);
          }
       windowMutex.UnLock();
      }

// All done
//
   return mp;
}

/******************************************************************************/
/*                                 F l u s h                                  */
/******************************************************************************/
  
void XrdXrootdMonitor::Flush()
{
   int       size;
   kXR_int32 now = static_cast<kXR_int32>(htonl((long)time(0)));

// Do not flush if the buffer is empty
//
   if (nextEnt <= 1) return;

// Fill in the header and in the process we will have the current time
//
   size = (nextEnt+1)*sizeof(XrdXrootdMonTrace)+sizeof(XrdXrootdMonHeader);
   fillHeader(&monBuff->hdr, 't', size);

// Place the ending timing mark, send off the buffer and reinitialize it
//
   monBuff->info[nextEnt].offset.id[0] = XROOTD_MON_WINDOW;
   monBuff->info[nextEnt].arg1.Window  =
   monBuff->info[nextEnt].arg2.Window  = now;
   Send((void *)monBuff, size);
   monBuff->info[      0].offset.id[0] = XROOTD_MON_WINDOW;
   monBuff->info[      0].arg1.Window  =
   monBuff->info[      0].arg2.Window  = now;
   nextEnt = 1;
}

/******************************************************************************/
/*                                  I n i t                                   */
/******************************************************************************/
  
int XrdXrootdMonitor::Init(XrdScheduler *sp, XrdOucError *errp,
                           char *dest, int msz, int wsz)
{

// Set various statics
//
   Sched = sp;
   eDest = errp;
   sizeWindow = wsz;
   if (msz < 1024) msz = 1024;
   lastEnt = (msz-sizeof(XrdXrootdMonHeader))/sizeof(XrdXrootdMonTrace);
   monBlen =  (lastEnt*sizeof(XrdXrootdMonTrace))+sizeof(XrdXrootdMonHeader);
   lastEnt--;
   startTime = static_cast<kXR_int32>(htonl((long)time(0)));

// Get a socket to send the monitor data
//
   if (!(monDest = XrdOucNetwork::Relay(eDest, OUC_SENDONLY, dest))) return 0;

// All done
//
   return 1;
}

/******************************************************************************/
/*                                   M a p                                    */
/******************************************************************************/
  
void XrdXrootdMonitor::Map(const char code, kXR_int32 dictID,
                           const char *uname, const char *path)
{
     XrdXrootdMonMap map;
     int             size;

// Copy in the username and path
//
   map.dictid = dictID;
   strcpy(map.info, uname);
   size = strlen(uname);
   *(map.info+size) = '\n';
   strlcpy(map.info+size+1, path, sizeof(map.info)-size-1);

// Fill in the header and send off the packet
//
   size = sizeof(XrdXrootdMonHeader)+size+1+sizeof(kXR_int32)+strlen(path);
   fillHeader(&map.hdr, code, size);
   Send((void *)&map, size);
}

/******************************************************************************/
/*                               s e t M o d e                                */
/******************************************************************************/

void XrdXrootdMonitor::setMode(int onoff)
{
   static XrdXrootdMonitor_Tick MonTick;
   time_t Now;
   int wasEnabled;

   windowMutex.Lock();
   wasEnabled = isEnabled;
   isEnabled = onoff;
   if (isEnabled > 0 && !wasEnabled)
      {MonTick.Set(Sched, sizeWindow);
       Now = time(0);
       currWindow = static_cast<kXR_int32>(Now);
       Sched->Schedule((XrdJob *)&MonTick, Now+sizeWindow);
      }
   windowMutex.UnLock();
}
  
/******************************************************************************/
/*                                  T i c k                                   */
/******************************************************************************/
  
time_t XrdXrootdMonitor::Tick()
{
   time_t Now;
   windowMutex.Lock();
   Now = time(0);
   currWindow = static_cast<kXR_int32>(Now);
   if (isEnabled < 0 && !numMonitor) Now = 0;
   windowMutex.UnLock();
   return Now;
}

/******************************************************************************/
/*                       P r i v a t e   M e t h o d s                        */
/******************************************************************************/
/******************************************************************************/
/*                            f i l l H e a d e r                             */
/******************************************************************************/
  
void XrdXrootdMonitor::fillHeader(XrdXrootdMonHeader *hdr,
                                  const char          id, int size)
{  static XrdOucMutex seqMutex;
   static int         seq = 0;
          int         myseq;

// Generate a new sequence number
//
   seqMutex.Lock();
   myseq = 0x00ff & (seq++);
   seqMutex.UnLock();

// Fill in the header
//
   hdr->code = static_cast<kXR_char>(id);
   hdr->pseq = static_cast<kXR_char>(myseq);
   hdr->plen = static_cast<kXR_int16>(htonl(size));
   hdr->stod = startTime;
}

/******************************************************************************/
/*                                  M a r k                                   */
/******************************************************************************/
  
void XrdXrootdMonitor::Mark()
{
   kXR_int32 localWindow;

// Get the current window marker. Since it might be updated while
// we are getting it, get a mutex to make sure it's fully updated
//
   windowMutex.Lock();
   localWindow = currWindow;
   windowMutex.UnLock();

// Now, optimize placing the window mark in the buffer
//
   if (monBuff->info[nextEnt-1].offset.id[0] == XROOTD_MON_WINDOW)
      monBuff->info[nextEnt-1].arg2.Window = 
               static_cast<kXR_int32>(ntohl(localWindow));
      else if (nextEnt+8 > lastEnt) Flush();
              else {monBuff->info[nextEnt].offset.id[0] = XROOTD_MON_WINDOW;
                    monBuff->info[nextEnt].arg1.Window  =
                             static_cast<kXR_int32>(ntohl(lastWindow+sizeWindow));
                    monBuff->info[nextEnt].arg2.Window  =
                             static_cast<kXR_int32>(ntohl(localWindow));
                    nextEnt++;
                   }
     lastWindow = localWindow;
}
 
/******************************************************************************/
/*                                  S e n d                                   */
/******************************************************************************/
  
int XrdXrootdMonitor::Send(void *buff, int blen)
{
    static XrdOucMutex sendMutex;
    int rc;

    sendMutex.Lock();
    rc = monDest->Send(buff, blen);
    sendMutex.UnLock();

    return rc;
}
