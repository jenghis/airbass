/*
 * Copyright 2016 Jenghis, LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Cocoa/Cocoa.h>

@protocol EventTapDelegate;

@interface EventTap : NSObject {
    id <EventTapDelegate> _delegate;
    CFMachPortRef _eventPort;
}

-(id)initWithDelegate:(id <EventTapDelegate>)delegate eventsOfInterest:(CGEventMask)eventMask;

@end

@protocol EventTapDelegate <NSObject>
-(BOOL)eventTap:(EventTap*)tap interceptEvent:(CGEventRef)event type:(uint32_t)type;
@end